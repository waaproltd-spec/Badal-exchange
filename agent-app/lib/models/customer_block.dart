/// Blocking a customer (Agent App, Customer Info): the status, why, and who did it when.

class BlockEntry {
  const BlockEntry({required this.action, this.reason, this.by, this.byRole, this.at});

  /// blocked | unblocked
  final String action;
  final String? reason;
  final String? by;
  final String? byRole;
  final DateTime? at;

  bool get isBlock => action == 'blocked';

  factory BlockEntry.fromJson(Map<String, dynamic> j) => BlockEntry(
        action: j['action'] as String? ?? 'blocked',
        reason: j['reason'] as String?,
        by: j['by'] as String?,
        byRole: j['byRole'] as String?,
        at: DateTime.tryParse(j['at'] as String? ?? '')?.toLocal(),
      );
}

class CustomerBlockInfo {
  const CustomerBlockInfo({required this.blocked, this.reason, this.blockedAt, this.history = const []});

  final bool blocked;
  final String? reason;
  final DateTime? blockedAt;

  /// Newest first.
  final List<BlockEntry> history;

  factory CustomerBlockInfo.fromJson(Map<String, dynamic> j) => CustomerBlockInfo(
        blocked: j['status'] == 'blocked',
        reason: j['blockedReason'] as String?,
        blockedAt: DateTime.tryParse(j['blockedAt'] as String? ?? '')?.toLocal(),
        history: [for (final h in (j['history'] as List? ?? const [])) BlockEntry.fromJson(h as Map<String, dynamic>)],
      );
}
