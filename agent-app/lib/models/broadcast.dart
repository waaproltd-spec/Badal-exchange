/// Scheduled mass messages on the Telegram support bot (migrations/*_scheduled_messages.sql).

class BroadcastRun {
  const BroadcastRun({
    required this.id,
    this.scheduleId,
    this.isTest = false,
    this.channel = 'telegram',
    required this.status,
    this.total = 0,
    this.sent = 0,
    this.failed = 0,
    this.skipped = 0,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String? scheduleId;
  final bool isTest;

  /// push | telegram
  final String channel;

  /// sending | done
  final String status;
  final int total;
  final int sent;
  final int failed;

  /// Push: customers with no device (never allowed notifications, or signed out): nothing to send.
  final int skipped;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get sending => status == 'sending';

  /// 0 to 100, of the messages handled (sent, failed or without a device) so far.
  int get percent => total == 0 ? 100 : (((sent + failed + skipped) * 100) ~/ total).clamp(0, 100);

  bool get isPush => channel == 'push';

  factory BroadcastRun.fromJson(Map<String, dynamic> j) => BroadcastRun(
        id: j['id'] as String,
        scheduleId: j['scheduleId'] as String?,
        isTest: j['isTest'] as bool? ?? false,
        channel: j['channel'] as String? ?? 'telegram',
        status: j['status'] as String? ?? 'done',
        total: (j['total'] as num?)?.toInt() ?? 0,
        sent: (j['sent'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        skipped: (j['skipped'] as num?)?.toInt() ?? 0,
        startedAt: DateTime.tryParse('${j['startedAt']}')?.toLocal(),
        finishedAt: DateTime.tryParse('${j['finishedAt']}')?.toLocal(),
      );
}

class BroadcastSchedule {
  const BroadcastSchedule({
    required this.id,
    this.title,
    required this.message,
    this.channels = const ['push'],
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

  /// The notification's title (push); null: "BADAL EXCHANGE".
  final String? title;
  final String message;

  /// 'push' (the Customer App) and / or 'telegram'.
  final List<String> channels;

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
  bool get push => channels.contains('push');
  bool get telegram => channels.contains('telegram');

  factory BroadcastSchedule.fromJson(Map<String, dynamic> j) {
    final last = j['lastRun'];
    return BroadcastSchedule(
      id: j['id'] as String,
      title: j['title'] as String?,
      message: j['message'] as String? ?? '',
      channels: [for (final c in (j['channels'] as List? ?? const ['telegram'])) '$c'],
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
    this.activeCustomers = 0,
    this.pushReachable = 0,
    this.eligibleCustomers = 0,
    this.sent = 0,
    this.failed = 0,
    this.pushSent = 0,
    this.pushFailed = 0,
    this.pushNoDevice = 0,
    this.telegramSent = 0,
    this.telegramFailed = 0,
    this.activeSchedules = 0,
    this.teamChatLinked = false,
  });

  final int registeredCustomers;

  /// Every active Customer App customer: who a scheduled push is for.
  final int activeCustomers;

  /// Of them, the ones with at least one device registered (a push can reach them).
  final int pushReachable;

  /// Active customers who linked their Telegram with the bot: the ones a Telegram message can reach.
  final int eligibleCustomers;

  /// Both channels together (tests excluded).
  final int sent;
  final int failed;
  final int pushSent;
  final int pushFailed;
  final int pushNoDevice;
  final int telegramSent;
  final int telegramFailed;
  final int activeSchedules;
  final bool teamChatLinked;

  factory BroadcastStats.fromJson(Map<String, dynamic> j) => BroadcastStats(
        registeredCustomers: (j['registeredCustomers'] as num?)?.toInt() ?? 0,
        activeCustomers: (j['activeCustomers'] as num?)?.toInt() ?? 0,
        pushReachable: (j['pushReachable'] as num?)?.toInt() ?? 0,
        eligibleCustomers: (j['eligibleCustomers'] as num?)?.toInt() ?? 0,
        sent: (j['sent'] as num?)?.toInt() ?? 0,
        failed: (j['failed'] as num?)?.toInt() ?? 0,
        pushSent: (j['pushSent'] as num?)?.toInt() ?? 0,
        pushFailed: (j['pushFailed'] as num?)?.toInt() ?? 0,
        pushNoDevice: (j['pushNoDevice'] as num?)?.toInt() ?? 0,
        telegramSent: (j['telegramSent'] as num?)?.toInt() ?? 0,
        telegramFailed: (j['telegramFailed'] as num?)?.toInt() ?? 0,
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
