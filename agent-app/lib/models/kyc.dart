import 'dart:convert';
import 'dart:typed_data';

/// One row of KYC Management (manage_kyc_applications).
class KycListItem {
  final String id;
  final String customerId;
  final String? customerName;
  final String phone;
  final String documentType; // passport | national_id
  final String documentNumber;
  final String fullName;
  final String country;
  final String status;
  final DateTime? submittedAt;
  final int failedChecks;

  const KycListItem({
    required this.id,
    required this.customerId,
    this.customerName,
    required this.phone,
    required this.documentType,
    required this.documentNumber,
    required this.fullName,
    required this.country,
    required this.status,
    this.submittedAt,
    required this.failedChecks,
  });

  factory KycListItem.fromJson(Map<String, dynamic> j) => KycListItem(
        id: j['id'] as String,
        customerId: j['customerId'] as String? ?? '',
        customerName: j['customerName'] as String?,
        phone: j['phone'] as String? ?? '',
        documentType: j['documentType'] as String? ?? '',
        documentNumber: j['documentNumber'] as String? ?? '',
        fullName: j['fullName'] as String? ?? '',
        country: j['country'] as String? ?? '',
        status: j['status'] as String? ?? '',
        submittedAt: j['submittedAt'] == null ? null : DateTime.tryParse(j['submittedAt'].toString()),
        failedChecks: (j['failedChecks'] as num?)?.toInt() ?? 0,
      );
}

class KycCheck {
  final String key;
  final bool ok;
  final String? detail;
  const KycCheck(this.key, this.ok, this.detail);
}

/// One application with its documents (manage_kyc_application).
class KycApplication {
  final KycListItem item;
  final String? dateOfBirth;
  final String? expiryDate;
  final List<KycCheck> checks;
  final String? provider;
  final String? reviewReason;
  final DateTime? decidedAt;
  final String? decidedBy;
  final String? decisionReason;
  final Map<String, Uint8List> documents; // front / back / selfie
  final List<Map<String, dynamic>> history;

  const KycApplication({
    required this.item,
    this.dateOfBirth,
    this.expiryDate,
    required this.checks,
    this.provider,
    this.reviewReason,
    this.decidedAt,
    this.decidedBy,
    this.decisionReason,
    required this.documents,
    required this.history,
  });

  bool get decided => const {'approved', 'rejected', 'resubmission_required'}.contains(item.status);

  factory KycApplication.fromJson(Map<String, dynamic> j) {
    final docs = (j['documents'] as Map?)?.cast<String, dynamic>() ?? const {};
    return KycApplication(
      item: KycListItem.fromJson(j),
      dateOfBirth: j['dateOfBirth'] as String?,
      expiryDate: j['expiryDate'] as String?,
      checks: ((j['checks'] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .map((c) => KycCheck(c['key'] as String? ?? '', c['ok'] as bool? ?? false, c['detail'] as String?))
          .toList(),
      provider: j['provider'] as String?,
      reviewReason: j['reviewReason'] as String?,
      decidedAt: j['decidedAt'] == null ? null : DateTime.tryParse(j['decidedAt'].toString()),
      decidedBy: j['decidedBy'] as String?,
      decisionReason: j['decisionReason'] as String?,
      documents: {
        for (final e in docs.entries)
          if ((e.value as Map?)?['data'] is String) e.key: base64Decode((e.value as Map)['data'] as String),
      },
      history: ((j['history'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList(),
    );
  }
}

const kycStatusLabels = {
  'pending_auto': 'Pending Automatic Verification',
  'pending_review': 'Pending Admin Review',
  'approved': 'Approved',
  'rejected': 'Rejected',
  'resubmission_required': 'Resubmission Required',
};
