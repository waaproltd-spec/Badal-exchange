
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/tr.dart';
import '../../models/tips.dart';
import '../../services/ad_image_picker.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

/// TIPS (Shaxaha) in the Admin Dashboard: create, edit, publish, delete, the purchase
/// history, sales and revenue. The backend lets only managers do this.

IconData tipSportIcon(String sport) => switch (sport) {
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

String tipSportName(String sport) => switch (sport) {
      'football' => tr('Football'),
      'basketball' => tr('Basketball'),
      'tennis' => tr('Tennis'),
      'volleyball' => tr('Volleyball'),
      'baseball' => tr('Baseball'),
      'hockey' => tr('Hockey'),
      'cricket' => tr('Cricket'),
      'rugby' => tr('Rugby'),
      'boxing' => tr('Boxing'),
      _ => tr('Other'),
    };

/// Keeps a form or list readable on a wide screen (the web).
Widget tipsCentered(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child),
    );

// ---------------------------------------------------------------------------
// Management list
// ---------------------------------------------------------------------------

class TipsManagementScreen extends StatefulWidget {
  const TipsManagementScreen({super.key});

  @override
  State<TipsManagementScreen> createState() => _TipsManagementScreenState();
}

class _TipsManagementScreenState extends ListScreenState<TipsManagementScreen, ManagedTip> {
  String _filter = 'all';
  TipsStats _stats = const TipsStats();

  @override
  Future<List<ManagedTip>> fetch() async {
    final tips = await api.getTips(_filter);
    try {
      _stats = await api.getTipsStats();
    } catch (_) {}
    return tips;
  }

  Future<void> _edit([ManagedTip? tip]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => TipFormScreen(tip: tip)));
    if (saved == true) load();
  }

  Future<void> _delete(ManagedTip t) async {
    final ok = await confirmDialog(context, trp('Delete "{0}"?', [t.title]),
        tr('Customers will no longer see this tip. The purchases stay in the history.'));
    if (ok) run(() => api.deleteTip(t.id), success: tr('Tip deleted.'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Tx('TIPS Management'),
        actions: [
          IconButton(
            key: const Key('tips-history'),
            tooltip: tr('Purchase history'),
            icon: const Icon(Icons.receipt_long_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TipPurchasesScreen(manager: true))),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('tip-add'),
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Tx('Add tip'),
      ),
      body: body(
        builder: (tips) => tipsCentered(
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              TipsStatsCard(stats: _stats),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final (key, label) in [
                    ('all', tr('All')),
                    ('published', tr('Published')),
                    ('draft', tr('Draft')),
                    ('free', tr('Free')),
                    ('paid', tr('Paid')),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: Key('tips-filter-$key'),
                        label: Text(label),
                        selected: _filter == key,
                        onSelected: (_) {
                          setState(() => _filter = key);
                          load();
                        },
                      ),
                    ),
                ]),
              ),
              const SizedBox(height: 12),
              if (tips.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: EmptyStateView(
                    icon: Icons.tips_and_updates_outlined,
                    title: tr('No tips yet'),
                    message: tr('Tips you add appear in the Customer App once you publish them.'),
                  ),
                ),
              for (final t in tips) ...[
                _TipRow(
                  tip: t,
                  onEdit: () => _edit(t),
                  onDelete: () => _delete(t),
                  onPublish: (v) => run(() => api.publishTip(t.id, v), success: v ? tr('Tip published.') : tr('Tip unpublished.')),
                  onHistory: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => TipPurchasesScreen(manager: true, tipId: t.id, title: t.title))),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.tip, required this.onEdit, required this.onDelete, required this.onPublish, required this.onHistory});

  final ManagedTip tip;
  final VoidCallback onEdit, onDelete, onHistory;
  final ValueChanged<bool> onPublish;

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      onTap: onEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            TintedIcon(icon: tipSportIcon(tip.sport), color: AppColors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tip.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text('${tipSportName(tip.sport)} • ${trp('{0} teams', [tip.teamCount])}',
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Switch(key: Key('tip-publish-${tip.id}'), value: tip.published, onChanged: onPublish),
            PopupMenuButton<String>(
              key: Key('tip-menu-${tip.id}'),
              onSelected: (v) => switch (v) {
                'edit' => onEdit(),
                'history' => onHistory(),
                _ => onDelete(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 'edit', child: Tx('Edit')),
                PopupMenuItem(value: 'history', child: Tx('Purchase history')),
                PopupMenuItem(value: 'delete', child: Tx('Delete')),
              ],
            ),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _Pill(tip.isPaid ? tr('Paid') : tr('Free'), tip.isPaid ? AppColors.accentOrange : AppColors.primary),
            _Pill(tip.published ? tr('Published') : tr('Draft'), tip.published ? AppColors.statusCompleted : AppColors.textSecondary),
            if (tip.isPaid) Text('\$${tip.price}', style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('${tr('Code')}: ${tip.oddsCode}', style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
          ]),
          if (tip.isPaid)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(trp('{0} sales • \${1} revenue', [tip.sales, tip.revenue]),
                  key: Key('tip-sales-${tip.id}'), style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 118),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(text, maxLines: 1, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
        ),
      );
}

/// Sales and revenue (a refund is not revenue).
class TipsStatsCard extends StatelessWidget {
  const TipsStatsCard({super.key, required this.stats});

  final TipsStats stats;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, String value, {Key? key}) => Expanded(
          child: Column(children: [
            FittedBox(fit: BoxFit.scaleDown, child: Text(value, key: key, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 19))),
            const SizedBox(height: 2),
            Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
          ]),
        );
    return ConsoleCard(
      key: const Key('tips-stats'),
      child: Column(children: [
        Row(children: [
          cell(tr('Total sales'), '${stats.sales}', key: const Key('tips-stat-sales')),
          cell(tr('Total revenue'), '\$${stats.revenue}', key: const Key('tips-stat-revenue')),
          cell(tr('Today'), '\$${stats.revenueToday}'),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          cell(tr('Last 7 days'), '\$${stats.revenue7d}'),
          cell(tr('Published'), '${stats.published}/${stats.tips}'),
          cell(tr('Refunded'), '\$${stats.refunded}'),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Create / edit
// ---------------------------------------------------------------------------

class TipFormScreen extends StatefulWidget {
  const TipFormScreen({super.key, this.tip, this.pickImage = pickAdImageFromGallery});

  final ManagedTip? tip;
  final AdImagePicker pickImage;

  @override
  State<TipFormScreen> createState() => _TipFormScreenState();
}

class _MatchFields {
  _MatchFields([TipMatchEntry? m])
      : match = TextEditingController(text: m?.match),
        pick = TextEditingController(text: m?.pick),
        odds = TextEditingController(text: m?.odds?.toString());

  final TextEditingController match, pick, odds;

  void dispose() {
    match.dispose();
    pick.dispose();
    odds.dispose();
  }
}

class _TipFormScreenState extends State<TipFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.tip?.title);
  late final _code = TextEditingController(text: widget.tip?.oddsCode);
  late final _price = TextEditingController(text: (widget.tip?.isPaid ?? false) ? widget.tip!.price : '');
  late final _teams = TextEditingController(text: widget.tip == null ? '' : '${widget.tip!.teamCount}');
  late final _totalOdds = TextEditingController(text: widget.tip?.totalOdds?.toString());
  late final _note = TextEditingController(text: widget.tip?.note);
  late String _sport = widget.tip?.sport ?? 'football';
  late bool _paid = widget.tip?.isPaid ?? false;
  late final List<_MatchFields> _matches = [for (final m in widget.tip?.matches ?? const <TipMatchEntry>[]) _MatchFields(m)];
  Uint8List? _picked;
  bool _removed = false;
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    for (final c in [_title, _code, _price, _teams, _totalOdds, _note]) {
      c.dispose();
    }
    for (final m in _matches) {
      m.dispose();
    }
    super.dispose();
  }

  String? _required(String? v) => (v ?? '').trim().isEmpty ? tr('Required') : null;

  String? _number(String? v, {bool required = true, double? min}) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return required ? tr('Required') : null;
    final n = double.tryParse(t);
    if (n == null || (min != null && n < min)) return tr('Enter a valid number');
    return null;
  }

  Future<void> _choose() async {
    Uint8List? bytes;
    try {
      bytes = await widget.pickImage();
    } catch (_) {
      if (mounted) setState(() => _problem = tr('Could not open the gallery.'));
      return;
    }
    if (bytes == null || !mounted) return;
    final why = adImageProblem(bytes);
    setState(() {
      if (why != null) {
        _problem = why;
      } else {
        _picked = bytes;
        _removed = false;
        _problem = null;
      }
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      final matches = [
        for (final m in _matches)
          if (m.match.text.trim().isNotEmpty)
            TipMatchEntry(match: m.match.text.trim(), pick: m.pick.text.trim(), odds: double.tryParse(m.odds.text.trim())),
      ];
      await context.read<Session>().api.saveTip(
            id: widget.tip?.id,
            title: _title.text.trim(),
            sport: _sport,
            teamCount: int.parse(_teams.text.trim()),
            isPaid: _paid,
            price: _paid ? _price.text.trim() : null,
            oddsCode: _code.text.trim(),
            totalOdds: double.tryParse(_totalOdds.text.trim()),
            matches: matches,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
            image: _picked,
            removeImage: _removed && _picked == null,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _problem = errorText(e, tr('Could not save the tip.'));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _picked ?? (_removed ? null : widget.tip?.image);
    return Scaffold(
      appBar: AppBar(title: Tx(widget.tip == null ? 'Add tip' : 'Edit tip')),
      body: tipsCentered(
        Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              TextFormField(
                key: const Key('tip-title'),
                controller: _title,
                maxLength: 120,
                decoration: InputDecoration(labelText: tr('Title')),
                validator: _required,
              ),
              DropdownButtonFormField<String>(
                key: const Key('tip-sport'),
                value: _sport,
                decoration: InputDecoration(labelText: tr('Sport category')),
                items: [for (final s in tipSports) DropdownMenuItem(value: s, child: Text(tipSportName(s)))],
                onChanged: (v) => setState(() => _sport = v ?? _sport),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('tip-teams'),
                controller: _teams,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: tr('Number of teams')),
                validator: (v) {
                  final n = int.tryParse((v ?? '').trim());
                  return n == null || n < 1 || n > 40 ? tr('Enter a number from 1 to 40') : null;
                },
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                key: const Key('tip-paid'),
                segments: [
                  ButtonSegment(value: false, label: Text(tr('Free'))),
                  ButtonSegment(value: true, label: Text(tr('Paid'))),
                ],
                selected: {_paid},
                onSelectionChanged: (s) => setState(() => _paid = s.first),
              ),
              if (_paid) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('tip-price'),
                  controller: _price,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: tr('Price (USD)'), prefixText: '\$ '),
                  validator: (v) => _number(v, min: 0.01),
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('tip-code'),
                controller: _code,
                maxLength: 200,
                decoration: InputDecoration(labelText: tr('Odds Code')),
                validator: _required,
              ),
              TextFormField(
                key: const Key('tip-total-odds'),
                controller: _totalOdds,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr('Total odds (optional)')),
                validator: (v) => _number(v, required: false, min: 0.01),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('tip-note'),
                controller: _note,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(labelText: tr('Note (optional)')),
              ),
              GroupLabel(tr('Match details & odds')),
              for (var i = 0; i < _matches.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ConsoleCard(
                    key: Key('tip-match-$i'),
                    child: Column(children: [
                      Row(children: [
                        Expanded(
                          child: TextFormField(
                            key: Key('tip-match-name-$i'),
                            controller: _matches[i].match,
                            decoration: InputDecoration(labelText: tr('Match (e.g. Arsenal v Chelsea)')),
                          ),
                        ),
                        IconButton(
                          key: Key('tip-match-remove-$i'),
                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.statusFailed),
                          onPressed: () => setState(() => _matches.removeAt(i).dispose()),
                        ),
                      ]),
                      Row(children: [
                        Expanded(
                          flex: 3,
                          child: TextFormField(
                            key: Key('tip-match-pick-$i'),
                            controller: _matches[i].pick,
                            decoration: InputDecoration(labelText: tr('Pick')),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: TextFormField(
                            key: Key('tip-match-odds-$i'),
                            controller: _matches[i].odds,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: InputDecoration(labelText: tr('Odds')),
                            validator: (v) => _number(v, required: false, min: 0.01),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('tip-add-match'),
                  onPressed: _matches.length >= 40 ? null : () => setState(() => _matches.add(_MatchFields())),
                  icon: const Icon(Icons.add_rounded),
                  label: const Tx('Add match'),
                ),
              ),
              GroupLabel(tr('Image (optional)')),
              if (shown != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(height: 140, width: double.infinity, child: Image.memory(shown, key: const Key('tip-image-preview'), fit: BoxFit.cover)),
                ),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  key: const Key('tip-image-choose'),
                  onPressed: _saving ? null : _choose,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: Tx(shown == null ? 'Choose Image' : 'Change Image'),
                ),
                if (shown != null)
                  TextButton(
                    key: const Key('tip-image-remove'),
                    onPressed: _saving ? null : () => setState(() { _picked = null; _removed = true; }),
                    child: const Tx('Remove'),
                  ),
              ]),
              if (_problem != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_problem!, key: const Key('tip-problem'), style: const TextStyle(color: AppColors.statusFailed)),
                ),
              const SizedBox(height: 18),
              FilledButton(
                key: const Key('tip-save'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Tx('Save'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Tx('A new tip is saved as a draft: publish it from the list when it is ready.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Purchases: the managers' history (with refunds) and the Agent App's view
// ---------------------------------------------------------------------------

class TipPurchasesScreen extends StatefulWidget {
  const TipPurchasesScreen({super.key, required this.manager, this.tipId, this.title});

  /// Managers see the history (of one tip or all) and can refund; other agents see it read-only.
  final bool manager;
  final String? tipId;
  final String? title;

  @override
  State<TipPurchasesScreen> createState() => _TipPurchasesScreenState();
}

class _TipPurchasesScreenState extends State<TipPurchasesScreen> {
  List<TipPurchaseRecord>? _rows;
  TipsStats? _stats;
  String? _error;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final api = context.read<Session>().api;
    try {
      if (widget.manager) {
        final rows = await api.getTipPurchases(tipId: widget.tipId);
        final stats = widget.tipId == null ? await api.getTipsStats() : null;
        if (mounted) setState(() { _rows = rows; _stats = stats; _error = null; });
      } else {
        final v = await api.getAgentTipPurchases(search: _search.text.trim().isEmpty ? null : _search.text.trim());
        if (mounted) setState(() { _rows = v.purchases; _stats = v.summary; _error = null; });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, tr('Failed to load.')));
    }
  }

  Future<void> _refund(TipPurchaseRecord p) async {
    final why = await showDialog<String>(context: context, builder: (_) => _RefundDialog(price: p.price));
    if (why == null || !mounted) return;
    try {
      await context.read<Session>().api.refundTipPurchase(p.id, why);
      if (mounted) showSnack(context, tr('Refunded.'));
    } catch (e) {
      if (mounted) showSnack(context, errorText(e, tr('Could not refund.')));
    }
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? tr(widget.manager ? 'Purchase history' : 'Tips purchases'))),
      body: rows == null
          ? (_error != null ? ErrorStateView(message: _error!, onRetry: _load) : const LoadingView())
          : RefreshIndicator(
              onRefresh: _load,
              child: tipsCentered(
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                  children: [
                    if (_stats != null) ...[TipsStatsCard(stats: _stats!), const SizedBox(height: 12)],
                    if (!widget.manager) ...[
                      TextField(
                        key: const Key('tips-search'),
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _load(),
                        decoration: InputDecoration(
                          hintText: tr('Search by customer, phone or tip'),
                          prefixIcon: const Icon(Icons.search_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (rows.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: EmptyStateView(
                          icon: Icons.receipt_long_outlined,
                          title: tr('No purchases yet'),
                          message: tr('When customers buy paid tips they appear here.'),
                        ),
                      ),
                    for (final p in rows) ...[
                      ConsoleCard(
                        key: Key('purchase-${p.id}'),
                        child: Row(children: [
                          TintedIcon(icon: tipSportIcon(p.sport), color: p.refunded ? AppColors.textSecondary : AppColors.primary),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                              Text([if ((p.customerName ?? '').isNotEmpty) p.customerName!, if ((p.customerPhone ?? '').isNotEmpty) p.customerPhone!].join(' • '),
                                  style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
                              if (p.createdAt != null)
                                Text(formatDateTime(p.createdAt!), style: TextStyle(fontSize: 12, color: AppColors.textFaint)),
                              if (p.refunded && (p.refundReason ?? '').isNotEmpty)
                                Text('${tr('Refund reason')}: ${p.refundReason}', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                            ]),
                          ),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Text('\$${p.price}', style: const TextStyle(fontWeight: FontWeight.w900)),
                            const SizedBox(height: 4),
                            _Pill(p.refunded ? tr('Refunded') : tr('Completed'), p.refunded ? AppColors.statusPending : AppColors.statusCompleted),
                            if (widget.manager && !p.refunded)
                              TextButton(
                                key: Key('refund-${p.id}'),
                                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                                onPressed: () => _refund(p),
                                child: const Tx('Refund'),
                              ),
                          ]),
                        ]),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

/// Asks for the reason of a refund; owns its text field so it is disposed with the dialog.
class _RefundDialog extends StatefulWidget {
  const _RefundDialog({required this.price});

  final String price;

  @override
  State<_RefundDialog> createState() => _RefundDialogState();
}

class _RefundDialogState extends State<_RefundDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(trp('Refund \${0}?', [widget.price])),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('The price goes back to the customer\'s wallet and the tip is locked again for them.')),
          const SizedBox(height: 10),
          TextField(key: const Key('refund-reason'), controller: _reason, decoration: InputDecoration(labelText: tr('Reason'))),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Tx('Cancel')),
        FilledButton(key: const Key('refund-confirm'), onPressed: () => Navigator.pop(context, _reason.text.trim()), child: const Tx('Refund')),
      ],
    );
  }
}
