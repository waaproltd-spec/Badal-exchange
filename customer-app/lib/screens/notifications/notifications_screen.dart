import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/strings.dart';
import '../../models/app_content.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import '../../utils/formatters.dart';

/// Ogeysiisyo: the customer's own money notifications (sent / received, deposit, withdrawal) with their details, and the messages
/// sent to everyone, newest first, read a page at a time (older ones load when the end of the list is reached).
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  static const _page = 30;

  final ScrollController _scroll = ScrollController();
  final List<AppNotification> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _more = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) _loadMore();
    });
    _first();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _first() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await context.read<CustomerApi>().getNotifications(limit: _page);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page);
        _more = page.length >= _page;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_more || _loading || _items.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final page = await context.read<CustomerApi>().getNotifications(before: _items.last.createdAt, limit: _page);
      if (!mounted) return;
      final have = _items.map((n) => n.id).toSet();
      setState(() {
        _items.addAll(page.where((n) => have.add(n.id))); // never the same notification twice
        _more = page.length >= _page;
      });
    } catch (_) {
      // Offline for a moment: the next scroll tries again.
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.screenBackground,
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.notifications_rounded, color: Color(0xFFFFC83D)),
          const SizedBox(width: 10),
          Flexible(child: Text(AppStrings.notifications, style: AppTextStyles.appBarTitle)),
        ]),
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _first,
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading && _items.isEmpty) return Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null && _items.isEmpty) {
      final e = _error;
      return ListView(children: [
        const SizedBox(height: 140),
        Center(child: Text(e is ApiException ? e.message : AppStrings.couldNotLoadNotifications, style: AppTextStyles.muted)),
      ]);
    }
    if (_items.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 140),
        Center(child: Text(AppStrings.noNotifications, style: AppTextStyles.muted)),
      ]);
    }
    return ListView.separated(
      key: const Key('notifications-list'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: _items.length + (_more ? 1 : 0),
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, i) {
        if (i >= _items.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.primary))),
          );
        }
        return NotificationCard(key: Key('notification-${_items[i].id}'), n: _items[i]);
      },
    );
  }
}

/// One notification: icon by kind, the title, a status badge, the details of the money movement, the transaction ID with a copy icon, the date.
class NotificationCard extends StatelessWidget {
  const NotificationCard({super.key, required this.n});

  final AppNotification n;

  static const _green = AppColors.success;
  static const _red = Color(0xFFFF4D5E);
  static const _orange = Color(0xFFF59E0B);
  static const _purple = Color(0xFFB57BFF);

  Color get _accent => switch (n.kind) {
        'withdraw' => _red,
        'deposit' || 'transfer_sent' || 'transfer_received' => _green,
        _ => const Color(0xFFFFC83D),
      };

  IconData get _icon => switch (n.kind) {
        'withdraw' => Icons.arrow_upward_rounded,
        'deposit' || 'transfer_received' => Icons.arrow_downward_rounded,
        'transfer_sent' => Icons.send_rounded,
        _ => Icons.notifications_rounded,
      };

  String get _title => switch (n.kind) {
        'transfer_sent' => AppStrings.notifTitleSent,
        'transfer_received' => AppStrings.notifTitleReceived,
        'withdraw' => AppStrings.notifTitleWithdraw,
        'deposit' => AppStrings.notifTitleDeposit,
        _ => n.title,
      };

  (String, Color, IconData) get _badge => switch (n.status) {
        'failed' => (AppStrings.notifStatusFailed, _red, Icons.close_rounded),
        'pending' || 'processing' => (AppStrings.notifStatusPending, _orange, Icons.schedule_rounded),
        _ => (AppStrings.notifStatusOk, _green, Icons.check_rounded),
      };

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accent.withOpacity(n.isMoney ? 0.55 : 0.4), width: 1.4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            child: Icon(_icon, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_title, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 16.5)),
            ),
          ),
          if (n.isMoney) ...[const SizedBox(width: 8), _StatusBadge(badge: _badge)],
        ]),
        const SizedBox(height: 10),
        if (!n.isMoney) Text(n.body, style: AppTextStyles.muted) else ..._details(context),
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.calendar_month_rounded, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Flexible(child: Text(Formatters.dateTime(n.createdAt), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.muted.copyWith(fontSize: 13))),
        ]),
      ]),
    );
  }

  List<Widget> _details(BuildContext context) {
    final transfer = n.kind == 'transfer_sent' || n.kind == 'transfer_received';
    final amountColor = n.kind == 'withdraw' || n.kind == 'transfer_sent' ? _red : _green;
    final sign = n.kind == 'withdraw' || n.kind == 'transfer_sent' ? '-' : '+';
    final rows = <(String, Widget)>[
      if (transfer && (n.counterpartName ?? '').isNotEmpty)
        (n.kind == 'transfer_sent' ? AppStrings.notifRecipient : AppStrings.notifSender, _val(n.counterpartName!, bold: true)),
      if (transfer && (n.counterpartWalletId ?? '').isNotEmpty) (AppStrings.notifWalletId, _val(n.counterpartWalletId!)),
      if (!transfer && (n.method ?? '').isNotEmpty) (AppStrings.notifProvider, _val(n.method!, bold: true)),
      if ((n.amount ?? '').isNotEmpty)
        (AppStrings.notifAmount, _val('$sign${Formatters.money(n.amount!)}', color: amountColor, bold: true, size: 17)),
      if ((n.balanceAfter ?? '').isNotEmpty) (AppStrings.notifBalance, _val(Formatters.money(n.balanceAfter!), color: const Color(0xFFFFC83D), bold: true)),
    ];
    final ref = n.copyRef;
    return [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: _purple.withOpacity(0.12), borderRadius: BorderRadius.circular(16)),
        child: Column(children: [
          for (var i = 0; i < rows.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Flexible(child: Text(rows[i].$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.muted.copyWith(fontSize: 13))),
                const SizedBox(width: 10),
                Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: rows[i].$2)),
              ]),
            ),
        ]),
      ),
      if (ref != null && ref.isNotEmpty) ...[
        const SizedBox(height: 10),
        // The transaction ID, in its own section, with a copy icon.
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          decoration: BoxDecoration(color: _purple.withOpacity(0.18), borderRadius: BorderRadius.circular(16), border: Border.all(color: _purple.withOpacity(0.4))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(AppStrings.transactionId, style: AppTextStyles.muted.copyWith(fontSize: 11.5)),
                Text(ref, key: Key('notification-ref-${n.id}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppTextStyles.body.copyWith(fontWeight: FontWeight.w800, fontSize: 15)),
              ]),
            ),
            IconButton(
              key: Key('notification-copy-${n.id}'),
              tooltip: AppStrings.transactionId,
              icon: const Icon(Icons.copy_rounded, size: 22),
              color: Colors.white,
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(ClipboardData(text: ref));
                messenger.showSnackBar(SnackBar(content: Text(AppStrings.copied(ref)), duration: const Duration(seconds: 2)));
              },
            ),
          ]),
        ),
      ],
    ];
  }

  Widget _val(String text, {Color? color, bool bold = false, double size = 14.5}) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: AppTextStyles.body.copyWith(fontSize: size, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color),
      );
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.badge});

  final (String, Color, IconData) badge;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 124),
        child: Container(
          key: const Key('notification-status'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: badge.$2.withOpacity(0.16), borderRadius: BorderRadius.circular(20), border: Border.all(color: badge.$2.withOpacity(0.7))),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(badge.$3, size: 16, color: badge.$2),
              const SizedBox(width: 4),
              Text(badge.$1, maxLines: 1, style: AppTextStyles.body.copyWith(color: badge.$2, fontWeight: FontWeight.w800, fontSize: 13)),
            ]),
          ),
        ),
      );
}
