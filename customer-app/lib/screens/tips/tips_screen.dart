import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/api_exception.dart';
import '../../api/customer_api.dart';
import '../../l10n/server_text.dart';
import '../../l10n/strings.dart';
import '../../models/tip.dart';
import '../../state/wallet_provider.dart';

/// The TIPS (Shaxaha) palette: dark green, whatever the app theme is.
class TipsColors {
  static const background = Color(0xFF06170F);
  static const surface = Color(0xFF0D2A1B);
  static const card = Color(0xFF123424);
  static const border = Color(0xFF1E4A33);
  static const accent = Color(0xFF2ECC71);
  static const accentDark = Color(0xFF14804A);
  static const gold = Color(0xFFF5C451);
  static const text = Color(0xFFEFFAF3);
  static const muted = Color(0xFF8FB3A0);
  static const error = Color(0xFFFF6B6B);
}

IconData sportIcon(String sport) => switch (sport) {
      'football' => Icons.sports_soccer_rounded,
      'basketball' => Icons.sports_basketball_rounded,
      'tennis' => Icons.sports_tennis_rounded,
      'volleyball' => Icons.sports_volleyball_rounded,
      'baseball' => Icons.sports_baseball_rounded,
      'hockey' => Icons.sports_hockey_rounded,
      'cricket' => Icons.sports_cricket_rounded,
      'rugby' => Icons.sports_rugby_rounded,
      'boxing' => Icons.sports_mma_rounded,
      _ => Icons.emoji_events_rounded,
    };

/// Copies [code] and says so.
Future<void> copyTipCode(BuildContext context, String code) async {
  final messenger = ScaffoldMessenger.of(context);
  await Clipboard.setData(ClipboardData(text: code));
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(AppStrings.codeCopied), duration: const Duration(seconds: 2)));
}

/// TIPS: All / Free / Paid. A free tip shows its Odds Code and can be copied by everyone.
/// A paid tip shows a locked code and its price until the customer pays for it from the wallet.
class TipsScreen extends StatefulWidget {
  const TipsScreen({super.key});

  @override
  State<TipsScreen> createState() => _TipsScreenState();
}

class _TipsScreenState extends State<TipsScreen> {
  List<Tip>? _tips;
  String? _error;
  final Set<String> _buying = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final tips = await context.read<CustomerApi>().getTips('all');
      if (mounted) {
        setState(() {
          _tips = tips;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = serverText(e.message, code: e.code));
    } catch (_) {
      if (mounted) setState(() => _error = AppStrings.tipsCouldNotLoad);
    }
  }

  void _replace(Tip tip) {
    final list = _tips;
    if (list == null) return;
    setState(() => _tips = [for (final t in list) t.id == tip.id ? tip : t]);
  }

  Future<void> _unlock(Tip tip) async {
    if (_buying.contains(tip.id)) return; // one purchase at a time per tip
    final price = tip.price ?? '0.00';
    final balance = context.read<WalletProvider?>()?.wallet?.availableBalance;
    final messenger = ScaffoldMessenger.of(context);
    if (balance != null && (double.tryParse(balance) ?? 0) < (double.tryParse(price) ?? 0)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(AppStrings.tipNotEnough)));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TipsColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(AppStrings.tipBuyTitle, style: const TextStyle(color: TipsColors.text, fontWeight: FontWeight.w800)),
        content: Text(AppStrings.tipBuyMessage(price, balance ?? '—'), style: const TextStyle(color: TipsColors.muted, height: 1.4)),
        actions: [
          TextButton(
            key: const Key('tip-buy-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel, style: const TextStyle(color: TipsColors.muted)),
          ),
          FilledButton(
            key: const Key('tip-buy-confirm'),
            style: FilledButton.styleFrom(backgroundColor: TipsColors.accent, foregroundColor: TipsColors.background),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('${AppStrings.tipBuyConfirm}  \$$price'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _buying.add(tip.id));
    try {
      final r = await context.read<CustomerApi>().buyTip(tip.id, expectedPrice: price);
      if (!mounted) return;
      _replace(r.tip);
      context.read<WalletProvider?>()?.load(silent: true);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(r.charged ? AppStrings.tipUnlocked(r.availableBalance) : AppStrings.tipAlreadyOwned)));
    } on ApiException catch (e) {
      if (!mounted) return;
      final text = switch (e.code) {
        'PRICE_CHANGED' => AppStrings.tipPriceChanged,
        'INSUFFICIENT_FUNDS' => AppStrings.tipNotEnough,
        _ => serverText(e.message, code: e.code),
      };
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
      if (e.code == 'PRICE_CHANGED' || e.code == 'TIP_NOT_FOUND') _load();
    } catch (_) {
      if (mounted) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(AppStrings.tipCouldNotBuy)));
        _load(); // the purchase may have gone through: show the truth
        context.read<WalletProvider?>()?.load(silent: true);
      }
    } finally {
      if (mounted) setState(() => _buying.remove(tip.id));
    }
  }

  Future<void> _open(Tip tip) async {
    final updated = await Navigator.of(context).push<Tip>(
      MaterialPageRoute(builder: (_) => TipDetailScreen(tip: tip, onUnlock: _unlock)),
    );
    if (updated != null && mounted) _replace(updated);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: TipsColors.background,
        appBar: AppBar(
          backgroundColor: TipsColors.background,
          foregroundColor: TipsColors.text,
          elevation: 0,
          centerTitle: true,
          title: Text(AppStrings.tips, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(56),
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: TipsColors.surface, borderRadius: BorderRadius.circular(16)),
              child: TabBar(
                key: const Key('tips-tabs'),
                indicator: BoxDecoration(color: TipsColors.accent, borderRadius: BorderRadius.circular(12)),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelColor: TipsColors.background,
                unselectedLabelColor: TipsColors.muted,
                labelStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
                tabs: [
                  Tab(height: 40, text: AppStrings.tipsAll),
                  Tab(height: 40, text: AppStrings.tipsFree),
                  Tab(height: 40, text: AppStrings.tipsPaid),
                ],
              ),
            ),
          ),
        ),
        body: TabBarView(
          children: [
            for (final f in const ['all', 'free', 'paid'])
              _TipList(
                key: Key('tips-list-$f'),
                tips: _tips == null
                    ? null
                    : [
                        for (final t in _tips!)
                          if (f == 'all' || (f == 'free' && !t.isPaid) || (f == 'paid' && t.isPaid)) t,
                      ],
                error: _error,
                buying: _buying,
                onRefresh: _load,
                onUnlock: _unlock,
                onOpen: _open,
              ),
          ],
        ),
      ),
    );
  }
}

class _TipList extends StatelessWidget {
  const _TipList({
    super.key,
    required this.tips,
    required this.error,
    required this.buying,
    required this.onRefresh,
    required this.onUnlock,
    required this.onOpen,
  });

  final List<Tip>? tips;
  final String? error;
  final Set<String> buying;
  final Future<void> Function() onRefresh;
  final Future<void> Function(Tip) onUnlock;
  final Future<void> Function(Tip) onOpen;

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (tips == null && error == null) {
      body = const Center(child: CircularProgressIndicator(color: TipsColors.accent));
    } else if (tips == null) {
      body = _Message(icon: Icons.cloud_off_rounded, text: error!, retry: onRefresh);
    } else if (tips!.isEmpty) {
      body = _Message(icon: Icons.tips_and_updates_outlined, text: AppStrings.tipsEmpty);
    } else {
      body = ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        itemCount: tips!.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => TipCard(
          key: Key('tip-${tips![i].id}'),
          tip: tips![i],
          busy: buying.contains(tips![i].id),
          onUnlock: () => onUnlock(tips![i]),
          onOpen: () => onOpen(tips![i]),
        ),
      );
    }
    return RefreshIndicator(
      color: TipsColors.accent,
      backgroundColor: TipsColors.surface,
      onRefresh: onRefresh,
      // Centered column on a wide screen (the web).
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: body),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text, this.retry});

  final IconData icon;
  final String text;
  final Future<void> Function()? retry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(icon, size: 56, color: TipsColors.muted),
        const SizedBox(height: 14),
        Text(text, textAlign: TextAlign.center, style: const TextStyle(color: TipsColors.muted, fontSize: 15)),
        if (retry != null) ...[
          const SizedBox(height: 14),
          Center(
            child: OutlinedButton(
              key: const Key('tips-retry'),
              style: OutlinedButton.styleFrom(foregroundColor: TipsColors.accent, side: const BorderSide(color: TipsColors.accent)),
              onPressed: retry,
              child: Text(AppStrings.retry),
            ),
          ),
        ],
      ],
    );
  }
}

/// One tip: sport, teams, Free / Paid, the Odds Code (locked for a paid tip not bought yet),
/// the price and the Copy Code / Unlock button.
class TipCard extends StatelessWidget {
  const TipCard({super.key, required this.tip, required this.onUnlock, this.onOpen, this.busy = false});

  final Tip tip;
  final VoidCallback onUnlock;
  final VoidCallback? onOpen;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final locked = tip.locked;
    final code = tip.oddsCode;
    return Material(
      color: TipsColors.card,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: tip.isPaid && !locked ? TipsColors.gold.withOpacity(0.5) : TipsColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: TipsColors.surface, borderRadius: BorderRadius.circular(14)),
                    child: Icon(sportIcon(tip.sport), color: TipsColors.accent, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tip.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: TipsColors.text, fontWeight: FontWeight.w800, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text('${AppStrings.sportName(tip.sport)} • ${tip.teamCount} ${AppStrings.tipTeams}',
                            key: Key('tip-meta-${tip.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: TipsColors.muted, fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _Badge(
                    key: Key('tip-badge-${tip.id}'),
                    text: tip.isPaid ? AppStrings.tipsPaid : AppStrings.tipsFree,
                    color: tip.isPaid ? TipsColors.gold : TipsColors.accent,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: TipsColors.surface, borderRadius: BorderRadius.circular(14)),
                child: Row(
                  children: [
                    Icon(locked ? Icons.lock_rounded : Icons.confirmation_number_rounded,
                        size: 20, color: locked ? TipsColors.gold : TipsColors.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(AppStrings.oddsCode, style: const TextStyle(color: TipsColors.muted, fontSize: 11.5)),
                          const SizedBox(height: 2),
                          Text(
                            locked ? '••••••••••' : (code ?? ''),
                            key: Key('tip-code-${tip.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: locked ? TipsColors.muted : TipsColors.text,
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              letterSpacing: locked ? 2 : 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (tip.totalOdds != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(AppStrings.tipTotalOdds, style: const TextStyle(color: TipsColors.muted, fontSize: 11.5)),
                            const SizedBox(height: 2),
                            Text(tip.totalOdds!.toStringAsFixed(2),
                                style: const TextStyle(color: TipsColors.gold, fontWeight: FontWeight.w800, fontSize: 15)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (tip.isPaid)
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(locked ? '\$${tip.price}' : AppStrings.tipOwned,
                          key: Key('tip-price-${tip.id}'),
                          style: TextStyle(
                              color: locked ? TipsColors.gold : TipsColors.accent, fontWeight: FontWeight.w800, fontSize: 18)),
                    ),
                  Expanded(
                    child: locked
                        ? FilledButton.icon(
                            key: Key('tip-unlock-${tip.id}'),
                            style: FilledButton.styleFrom(
                                backgroundColor: TipsColors.gold,
                                foregroundColor: TipsColors.background,
                                minimumSize: const Size(0, 44),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                            onPressed: busy ? null : onUnlock,
                            icon: busy
                                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: TipsColors.background))
                                : const Icon(Icons.lock_open_rounded, size: 18),
                            label: Text(AppStrings.unlockTip, style: const TextStyle(fontWeight: FontWeight.w800)),
                          )
                        : FilledButton.icon(
                            key: Key('tip-copy-${tip.id}'),
                            style: FilledButton.styleFrom(
                                backgroundColor: TipsColors.accent,
                                foregroundColor: TipsColors.background,
                                minimumSize: const Size(0, 44),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                            onPressed: code == null ? null : () => copyTipCode(context, code),
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: Text(AppStrings.copyCode, style: const TextStyle(fontWeight: FontWeight.w800)),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
    );
  }
}

/// A tip in full: the matches with their picks and odds, the note and the picture. For a tip not
/// bought yet the server sends none of it, so only the teaser and the Unlock button show.
class TipDetailScreen extends StatefulWidget {
  const TipDetailScreen({super.key, required this.tip, required this.onUnlock});

  final Tip tip;
  final Future<void> Function(Tip) onUnlock;

  @override
  State<TipDetailScreen> createState() => _TipDetailScreenState();
}

class _TipDetailScreenState extends State<TipDetailScreen> {
  late Tip _tip = widget.tip;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  /// The list has no pictures: fetch this tip with its picture.
  Future<void> _reload() async {
    try {
      final t = await context.read<CustomerApi>().getTip(widget.tip.id);
      if (mounted) setState(() => _tip = t);
    } catch (_) {}
  }

  Future<void> _unlock() async {
    setState(() => _busy = true);
    await widget.onUnlock(_tip);
    if (mounted) {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tip = _tip;
    final image = tip.imageBytes;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_tip);
      },
      child: Scaffold(
        backgroundColor: TipsColors.background,
        appBar: AppBar(
          backgroundColor: TipsColors.background,
          foregroundColor: TipsColors.text,
          elevation: 0,
          title: Text(tip.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              children: [
                TipCard(tip: tip, busy: _busy, onUnlock: _unlock),
                if (image != null) ...[
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.memory(image, key: const Key('tip-image'), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
                  ),
                ],
                if (tip.note != null && tip.note!.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text(tip.note!, style: const TextStyle(color: TipsColors.muted, height: 1.4)),
                ],
                if (tip.matches.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(AppStrings.tipMatches, style: const TextStyle(color: TipsColors.text, fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 8),
                  for (final m in tip.matches)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(color: TipsColors.surface, borderRadius: BorderRadius.circular(14)),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(m.match, style: const TextStyle(color: TipsColors.text, fontWeight: FontWeight.w700)),
                                if (m.pick.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(m.pick, style: const TextStyle(color: TipsColors.muted, fontSize: 13)),
                                  ),
                              ],
                            ),
                          ),
                          if (m.odds != null)
                            Text(m.odds!.toStringAsFixed(2),
                                style: const TextStyle(color: TipsColors.gold, fontWeight: FontWeight.w800, fontSize: 16)),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
