import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/agent_api.dart';
import '../../l10n/tr.dart';
import '../../models/broadcast.dart';
import '../../state/session.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console_widgets.dart';
import '../../widgets/state_views.dart';
import '../manage_screens.dart';

/// Scheduled mass messages on the Telegram support bot: every day, week or month, at a time in Mogadishu
/// (GMT+3), to every customer who linked Telegram. Managers create, edit, pause, resume and delete them;
/// the backend lets only managers do this and sends the messages by itself.

String weekdayName(int day) => switch (day) {
      1 => tr('Monday'),
      2 => tr('Tuesday'),
      3 => tr('Wednesday'),
      4 => tr('Thursday'),
      5 => tr('Friday'),
      6 => tr('Saturday'),
      _ => tr('Sunday'),
    };

/// A moment in Mogadishu time (GMT+3), whatever the phone's own time zone.
String mogadishu(DateTime d) {
  final t = d.toUtc().add(const Duration(hours: 3));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// "08:00" as "08:00 AM".
String timeLabel(String hhmm) {
  final p = hhmm.split(':');
  final h = int.tryParse(p.first) ?? 0;
  final m = p.length > 1 ? p[1] : '00';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '${h12.toString().padLeft(2, '0')}:$m ${h < 12 ? 'AM' : 'PM'}';
}

String kindLabel(String kind) => switch (kind) {
      'weekly' => tr('Weekly'),
      'monthly' => tr('Monthly'),
      _ => tr('Daily'),
    };

/// "Every day at 08:00 AM", "Every Sunday at ...", "On day 1 of every month at ...".
String scheduleSummary(String kind, String time, {int? weekday, int? monthDay}) {
  final at = timeLabel(time);
  return switch (kind) {
    'weekly' => trp('Every {0} at {1} (Mogadishu time)', [weekdayName(weekday ?? 1), at]),
    'monthly' => trp('On day {0} of every month at {1} (Mogadishu time)', [monthDay ?? 1, at]),
    _ => trp('Every day at {0} (Mogadishu time)', [at]),
  };
}

Widget broadcastCentered(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: child),
    );

// ---------------------------------------------------------------------------
// The list
// ---------------------------------------------------------------------------

class BroadcastScreen extends StatefulWidget {
  const BroadcastScreen({super.key});

  @override
  State<BroadcastScreen> createState() => _BroadcastScreenState();
}

class _BroadcastScreenState extends ListScreenState<BroadcastScreen, BroadcastSchedule> {
  BroadcastData _data = const BroadcastData();
  Timer? _poll;

  @override
  Future<List<BroadcastSchedule>> fetch() async {
    _data = await api.getBroadcasts();
    // While a message is being sent, the progress follows by itself.
    _poll?.cancel();
    _poll = _data.sendingNow == null ? null : Timer(const Duration(seconds: 8), () {
      if (mounted) load();
    });
    return _data.schedules;
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _edit([BroadcastSchedule? s]) async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => BroadcastFormScreen(schedule: s)));
    if (saved == true) load();
  }

  Future<void> _delete(BroadcastSchedule s) async {
    final ok = await confirmDialog(context, tr('Delete this schedule?'),
        tr('It stops and is removed from the list. Messages already sent stay as sent.'));
    if (ok) run(() => api.deleteBroadcast(s.id), success: tr('Schedule deleted.'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Tx('Scheduled Messages')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('broadcast-add'),
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Tx('Add schedule'),
      ),
      body: body(
        builder: (schedules) => broadcastCentered(
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              BroadcastStatsGrid(stats: _data.stats),
              const SizedBox(height: 8),
              Tx(
                'Messages go out by themselves to every active customer: as a push notification in the Customer App and / or on Telegram.',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
              ),
              if (_data.sendingNow != null) ...[
                const SizedBox(height: 12),
                BroadcastProgressCard(run: _data.sendingNow!),
              ],
              const SizedBox(height: 12),
              if (schedules.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: EmptyStateView(
                    icon: Icons.schedule_send_rounded,
                    title: tr('No scheduled messages yet'),
                    message: tr('Create a message and choose when it is sent: it goes out by itself.'),
                  ),
                ),
              for (final s in schedules) ...[
                _ScheduleRow(
                  schedule: s,
                  onEdit: () => _edit(s),
                  onDelete: () => _delete(s),
                  onActive: (v) => run(() => api.setBroadcastActive(s.id, v), success: v ? tr('Schedule resumed.') : tr('Schedule paused.')),
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

/// Total customers, notifications sent, failed, active schedules.
class BroadcastStatsGrid extends StatelessWidget {
  const BroadcastStatsGrid({super.key, required this.stats});

  final BroadcastStats stats;

  @override
  Widget build(BuildContext context) {
    return TwoColumnGrid(key: const Key('broadcast-stats'), children: [
      StatCard(
        key: const Key('broadcast-stat-customers'),
        icon: Icons.groups_rounded,
        color: AppColors.primary,
        value: '${stats.activeCustomers}',
        label: tr('Total customers'),
        caption: trp('{0} with notifications • {1} on Telegram', [stats.pushReachable, stats.eligibleCustomers]),
      ),
      StatCard(
        key: const Key('broadcast-stat-sent'),
        icon: Icons.send_rounded,
        color: AppColors.statusCompleted,
        value: '${stats.sent}',
        label: tr('Notifications sent'),
        caption: trp('Push {0} • Telegram {1}', [stats.pushSent, stats.telegramSent]),
      ),
      StatCard(
        key: const Key('broadcast-stat-failed'),
        icon: Icons.error_outline_rounded,
        color: AppColors.statusFailed,
        value: '${stats.failed}',
        label: tr('Failed'),
        caption: trp('Push {0} • Telegram {1}', [stats.pushFailed, stats.telegramFailed]),
      ),
      StatCard(
        key: const Key('broadcast-stat-active'),
        icon: Icons.schedule_send_rounded,
        color: AppColors.purple,
        value: '${stats.activeSchedules}',
        label: tr('Active schedules'),
      ),
    ]);
  }
}

/// Sending progress: a bar and the sent / failed / total counts.
class BroadcastProgressCard extends StatelessWidget {
  const BroadcastProgressCard({super.key, required this.run});

  final BroadcastRun run;

  @override
  Widget build(BuildContext context) {
    return ConsoleCard(
      key: const Key('broadcast-progress'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(
              '${tr('Sending progress')} • ${run.isPush ? tr('Push notification') : tr('Telegram')}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          Text('${run.percent}%', key: const Key('broadcast-percent'), style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(value: run.percent / 100, minHeight: 10, color: AppColors.statusCompleted),
        ),
        const SizedBox(height: 8),
        Text(trp('Sent {0} • Failed {1} • Total {2}', [run.sent, run.failed, run.total]),
            key: const Key('broadcast-counts'), style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary)),
        if (run.skipped > 0)
          Text(trp('{0} customers have no device (notifications off or signed out).', [run.skipped]),
              key: const Key('broadcast-skipped'), style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      ]),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({required this.schedule, required this.onEdit, required this.onDelete, required this.onActive});

  final BroadcastSchedule schedule;
  final VoidCallback onEdit, onDelete;
  final ValueChanged<bool> onActive;

  @override
  Widget build(BuildContext context) {
    final s = schedule;
    final last = s.lastRun;
    final color = s.active ? AppColors.statusCompleted : AppColors.textSecondary;
    return ConsoleCard(
      onTap: onEdit,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TintedIcon(icon: Icons.schedule_send_rounded, color: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${kindLabel(s.kind)} • ${timeLabel(s.time)}', style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(
                scheduleSummary(s.kind, s.time, weekday: s.weekday, monthDay: s.monthDay),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: AppColors.textSecondary),
              ),
            ]),
          ),
          Switch(key: Key('broadcast-active-${s.id}'), value: s.active, onChanged: onActive),
          PopupMenuButton<String>(
            key: Key('broadcast-menu-${s.id}'),
            onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Tx('Edit')),
              PopupMenuItem(value: 'delete', child: Tx('Delete')),
            ],
          ),
        ]),
        const SizedBox(height: 8),
        if (s.title != null && s.title!.isNotEmpty)
          Text(s.title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
        Text(s.message, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.textPrimary)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final c in s.channels)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(c == 'push' ? Icons.notifications_active_rounded : Icons.send_rounded, size: 13, color: AppColors.primary),
                const SizedBox(width: 4),
                Text(c == 'push' ? tr('Push') : tr('Telegram'),
                    key: Key('broadcast-channel-${s.id}-$c'), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.primary)),
              ]),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
            child: Text(s.active ? tr('Active') : tr('Paused'),
                key: Key('broadcast-status-${s.id}'), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
          ),
          if (s.active && s.nextRunAt != null)
            Text(trp('Next: {0}', [mogadishu(s.nextRunAt!)]), style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (last != null)
            Text(trp('Last run: {0} sent, {1} failed', [last.sent, last.failed]),
                key: Key('broadcast-last-${s.id}'), style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Create / edit
// ---------------------------------------------------------------------------

class BroadcastFormScreen extends StatefulWidget {
  const BroadcastFormScreen({super.key, this.schedule});

  final BroadcastSchedule? schedule;

  @override
  State<BroadcastFormScreen> createState() => _BroadcastFormScreenState();
}

class _BroadcastFormScreenState extends State<BroadcastFormScreen> {
  static const _maxLength = 4000;
  late final TextEditingController _message;
  late final TextEditingController _title;
  final _testPhone = TextEditingController();
  late bool _push;
  late bool _telegram;
  late String _kind;
  late TimeOfDay _time;
  late int _weekday;
  late int _monthDay;
  late bool _activate;
  bool _saving = false;
  bool _testing = false;
  String? _error;

  AgentApi get _api => context.read<Session>().api;

  @override
  void initState() {
    super.initState();
    final s = widget.schedule;
    _message = TextEditingController(text: s?.message ?? '');
    _title = TextEditingController(text: s?.title ?? '');
    // A new schedule is a push notification to the Customer App; Telegram is the other channel.
    _push = s?.push ?? true;
    _telegram = s?.telegram ?? false;
    _kind = s?.kind ?? 'daily';
    final parts = (s?.time ?? '08:00').split(':');
    _time = TimeOfDay(hour: int.tryParse(parts.first) ?? 8, minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0);
    _weekday = s?.weekday ?? 7;
    _monthDay = s?.monthDay ?? 1;
    _activate = s?.active ?? true;
  }

  @override
  void dispose() {
    _message.dispose();
    _title.dispose();
    _testPhone.dispose();
    super.dispose();
  }

  String get _hhmm => '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime() async {
    final t = await showTimePicker(context: context, initialTime: _time);
    if (t != null) setState(() => _time = t);
  }

  void _preview() {
    final text = _message.text.trim();
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        key: const Key('broadcast-preview'),
        title: const Tx('Preview'),
        content: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.10), borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (_push)
                Text(_title.text.trim().isEmpty ? 'BADAL EXCHANGE' : _title.text.trim(),
                    key: const Key('broadcast-preview-title'), style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(text.isEmpty ? tr('Write the message first.') : text, key: const Key('broadcast-preview-text')),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Tx('Close'))],
      ),
    );
  }

  Future<void> _test() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = tr('Write the message first.'));
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      await _api.testBroadcast(text);
      if (mounted) showSnack(context, tr('Test message sent to the team chat.'));
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, tr('Something went wrong.')));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _testPush() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = tr('Write the message first.'));
      return;
    }
    if (_testPhone.text.trim().isEmpty) {
      setState(() => _error = tr('Enter the phone number of a Customer App account for the test.'));
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
    });
    try {
      final hasDevice = await _api.testPush(title: _title.text.trim(), message: text, phone: _testPhone.text.trim());
      if (mounted) {
        showSnack(context, hasDevice ? tr('Test notification queued: it arrives within a minute.') : tr('That customer has no device registered: the app must be open once with notifications allowed.'));
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, tr('Something went wrong.')));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final text = _message.text.trim();
    if (text.isEmpty) {
      setState(() => _error = tr('Write the message first.'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.saveBroadcast(
        id: widget.schedule?.id,
        message: text,
        kind: _kind,
        time: _hhmm,
        weekday: _weekday,
        monthDay: _monthDay,
        active: _activate,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
        channels: [if (_push) 'push', if (_telegram) 'telegram'],
      );
      if (mounted) {
        showSnack(context, tr('Schedule saved.'));
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e, tr('Something went wrong.')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.schedule != null;
    return Scaffold(
      appBar: AppBar(title: Tx(editing ? 'Edit schedule' : 'New schedule')),
      body: broadcastCentered(
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Tx('Send through', style: const TextStyle(fontWeight: FontWeight.w800)),
            SwitchListTile(
              key: const Key('broadcast-channel-push'),
              contentPadding: EdgeInsets.zero,
              value: _push,
              onChanged: (v) => setState(() {
                _push = v;
                if (!_push && !_telegram) _telegram = true; // at least one
              }),
              title: const Tx('Push notification (Customer App)'),
              subtitle: const Tx('Every active customer, even with the app closed.'),
            ),
            SwitchListTile(
              key: const Key('broadcast-channel-telegram'),
              contentPadding: EdgeInsets.zero,
              value: _telegram,
              onChanged: (v) => setState(() {
                _telegram = v;
                if (!_push && !_telegram) _push = true;
              }),
              title: const Tx('Telegram'),
              subtitle: const Tx('Customers who linked Telegram with the bot.'),
            ),
            if (_push) ...[
              const SizedBox(height: 8),
              Tx('Title', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              TextField(
                key: const Key('broadcast-title'),
                controller: _title,
                maxLength: 100,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'BADAL EXCHANGE'),
              ),
            ],
            const SizedBox(height: 4),
            Tx('Message', style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            TextField(
              key: const Key('broadcast-message'),
              controller: _message,
              minLines: 4,
              maxLines: 10,
              maxLength: _maxLength,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: tr('Write the message for your customers…')),
            ),
            const SizedBox(height: 12),
            Tx('Schedule type', style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              for (final k in ['daily', 'weekly', 'monthly'])
                ChoiceChip(
                  key: Key('broadcast-kind-$k'),
                  label: Text(kindLabel(k)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ]),
            const SizedBox(height: 12),
            Tx('Time (Mogadishu, GMT+3)', style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              key: const Key('broadcast-time'),
              onPressed: _pickTime,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: const Icon(Icons.schedule_rounded),
              label: Text(timeLabel(_hhmm)),
            ),
            if (_kind == 'weekly') ...[
              const SizedBox(height: 12),
              Tx('Day of the week', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 4, children: [
                for (var d = 1; d <= 7; d++)
                  ChoiceChip(
                    key: Key('broadcast-weekday-$d'),
                    label: Text(weekdayName(d)),
                    selected: _weekday == d,
                    onSelected: (_) => setState(() => _weekday = d),
                  ),
              ]),
            ],
            if (_kind == 'monthly') ...[
              const SizedBox(height: 12),
              Tx('Day of the month', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              DropdownButtonFormField<int>(
                key: const Key('broadcast-monthday'),
                value: _monthDay,
                items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
                onChanged: (v) => setState(() => _monthDay = v ?? 1),
              ),
              const SizedBox(height: 4),
              Tx('A shorter month sends on its last day.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 12),
            ConsoleCard(
              key: const Key('broadcast-summary'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Tx('Summary', style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(scheduleSummary(_kind, _hhmm, weekday: _weekday, monthDay: _monthDay), key: const Key('broadcast-summary-text')),
              ]),
            ),
            SwitchListTile(
              key: const Key('broadcast-activate'),
              contentPadding: EdgeInsets.zero,
              value: _activate,
              onChanged: (v) => setState(() => _activate = v),
              title: const Tx('Start sending'),
              subtitle: const Tx('Off: the schedule is saved paused.'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!, key: const Key('broadcast-error'), style: TextStyle(color: AppColors.statusFailed)),
              ),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('broadcast-preview-button'),
                  onPressed: _preview,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Tx('Preview'),
                ),
              ),
              if (_telegram) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('broadcast-test-button'),
                    onPressed: _testing ? null : _test,
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    icon: const Icon(Icons.send_outlined),
                    label: const Tx('Test message'),
                  ),
                ),
              ],
            ]),
            if (_push) ...[
              const SizedBox(height: 12),
              Tx('Test notification', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              TextField(
                key: const Key('broadcast-test-phone'),
                controller: _testPhone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(hintText: tr('Customer phone number')),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('broadcast-test-push-button'),
                onPressed: _testing ? null : _testPush,
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Tx('Test push'),
              ),
              const SizedBox(height: 4),
              Tx('Goes to this one customer only, never to everyone.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ],
            const SizedBox(height: 8),
            ElevatedButton.icon(
              key: const Key('broadcast-save'),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.check_rounded),
              label: Tx(editing ? 'Save changes' : 'Create schedule'),
            ),
          ],
        ),
      ),
    );
  }
}
