/// The customer's KYC (customer_kyc_status). Statuses: not_submitted,
/// pending_auto, pending_review, approved, rejected, resubmission_required.
class KycStatus {
  const KycStatus({
    required this.status,
    required this.canSubmit,
    this.documentType,
    this.fullName,
    this.documentNumber,
    this.country,
    this.submittedAt,
    this.autoCheckedAt,
    this.decidedAt,
    this.reason,
  });

  final String status;
  final bool canSubmit;
  final String? documentType;
  final String? fullName;
  final String? documentNumber;
  final String? country;
  final DateTime? submittedAt;
  final DateTime? autoCheckedAt;
  final DateTime? decidedAt;

  /// The admin's reason, for a rejection or a resubmission.
  final String? reason;

  bool get approved => status == 'approved';
  bool get pending => status == 'pending_auto' || status == 'pending_review';

  static DateTime? _date(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());

  factory KycStatus.fromJson(Map<String, dynamic> j) => KycStatus(
        status: j['status'] as String? ?? 'not_submitted',
        canSubmit: j['canSubmit'] as bool? ?? false,
        documentType: j['documentType'] as String?,
        fullName: j['fullName'] as String?,
        documentNumber: j['documentNumber'] as String?,
        country: j['country'] as String?,
        submittedAt: _date(j['submittedAt']),
        autoCheckedAt: _date(j['autoCheckedAt']),
        decidedAt: _date(j['decidedAt']),
        reason: j['reason'] as String?,
      );
}
