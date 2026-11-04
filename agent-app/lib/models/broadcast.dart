/// Scheduled mass messages on the Telegram support bot (migrations/*_scheduled_messages.sql).

class BroadcastRun {
  const BroadcastRun({
    required this.id,
    this.scheduleId,
    this.isTest = false,
    required this.status,
    this.total = 0,
    this.sent = 0,
    this.failed = 0,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String? scheduleId;
  final bool isTest;

  /// sending | done
  final String status;
  final int total;
  final int sent;
  final int failed;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get sending => status == 'sending';

  /// 0 to 100, of the messages handled (sent or failed) so far.
  int get percent => total == 0 ? 100 : (((sent + failed) * 100) ~/ total).clamp(0, 100);

  factory BroadcastRun.fromJson(Map<String, dynamic> j) => BroadcastRun(
        id: j['id'] as String,
        scheduleId: j['scheduleId'] as String?,
        isTest: j['isTest'] as bool? ?? false,
        status: j['status'] as String? ?? 'done',
        total: (j['total'] as num?)?.toInt() ?? 0,
        sent: (j['sent'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        startedAt: DateTime.tryParse('${j['startedAt']}')?.toLocal(),
        finishedAt: DateTime.tryParse('${j['finishedAt']}')?.toLocal(),
      );
}

class BroadcastSchedule {
  const BroadcastSchedule({
    required this.id,
    required this.message,
    required this.kind,
    required this.time,
    this.weekday,
    this.monthDay,
    required this.status,
    this.nextRunAt,
    this.lastRunAt,
    this.lastRun,
  });

  final String id;
  final String message;

  /// daily | weekly | monthly
  final String kind;

  /// "08:00" in Mogadishu time.
  final String time;

  /// 1 = Monday ... 7 = Sunday (weekly).
  final int? weekday;
  final int? monthDay;

  /// active | paused
  final String status;
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;
  final BroadcastRun? lastRun;

  bool get active => status == 'active';

  factory BroadcastSchedule.fromJson(Map<String, dynamic> j) {
    final last = j['lastRun'];
    return BroadcastSchedule(
      id: j['id'] as String,
      message: j['message'] as String? ?? '',
      kind: j['kind'] as String? ?? 'daily',
      time: j['time'] as String? ?? '08:00',
      weekday: (j['weekday'] as num?)?.toInt(),
      monthDay: (j['monthDay'] as num?)?.toInt(),
      status: j['status'] as String? ?? 'active',
      nextRunAt: DateTime.tryParse('${j['nextRunAt']}')?.toLocal(),
      lastRunAt: DateTime.tryParse('${j['lastRunAt']}')?.toLocal(),
      lastRun: last is Map
          ? BroadcastRun.fromJson({'id': '', ...Map<String, dynamic>.from(last)})
          : null,
    );
  }
}

class BroadcastStats {
  const BroadcastStats({
    this.registeredCustomers = 0,
    this.eligibleCustomers = 0,
    this.sent = 0,
    this.failed = 0,
    this.activeSchedules = 0,
    this.teamChatLinked = false,
  });

  final int registeredCustomers;

  /// Active customers who linked their Telegram with the bot: the ones a message can reach.
  final int eligibleCustomers;
  final int sent;
  final int failed;
  final int activeSchedules;
  final bool teamChatLinked;

  factory BroadcastStats.fromJson(Map<String, dynamic> j) => BroadcastStats(
        registeredCustomers: (j['registeredCustomers'] as num?)?.toInt() ?? 0,
        eligibleCustomers: (j['eligibleCustomers'] as num?)?.toInt() ?? 0,
        sent: (j['sent'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        activeSchedules: (j['activeSchedules'] as num?)?.toInt() ?? 0,
        teamChatLinked: j['teamChatLinked'] as bool? ?? false,
      );
}

class BroadcastData {
  const BroadcastData({this.stats = const BroadcastStats(), this.schedules = const [], this.runs = const []});

  final BroadcastStats stats;
  final List<BroadcastSchedule> schedules;

  /// The latest runs, newest first (tests included).
  final List<BroadcastRun> runs;

  /// The run being sent now, if any (not a test).
  BroadcastRun? get sendingNow {
    for (final r in runs) {
      if (r.sending && !r.isTest) return r;
    }
    return null;
  }

  factory BroadcastData.fromJson(Map<String, dynamic> j) => BroadcastData(
        stats: BroadcastStats.fromJson(Map<String, dynamic>.from(j['stats'] as Map? ?? const {})),
        schedules: [for (final s in (j['schedules'] as List? ?? const [])) BroadcastSchedule.fromJson(Map<String, dynamic>.from(s as Map))],
        runs: [for (final r in (j['runs'] as List? ?? const [])) BroadcastRun.fromJson(Map<String, dynamic>.from(r as Map))],
      );
}
