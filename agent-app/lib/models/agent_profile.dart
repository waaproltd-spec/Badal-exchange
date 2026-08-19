/// Mirrors the response of GET /agent/profile.
class AgentProfile {
  final String id;
  final String name;
  final String phone;
  final String status;
  final List<String> responsibilities;
  final DateTime? lastSeenAt;

  const AgentProfile({
    required this.id,
    required this.name,
    required this.phone,
    required this.status,
    required this.responsibilities,
    this.lastSeenAt,
  });

  factory AgentProfile.fromJson(Map<String, dynamic> json) {
    final rawResponsibilities = json['responsibilities'];
    return AgentProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      status: json['status'] as String? ?? '',
      responsibilities: rawResponsibilities is List
          ? rawResponsibilities.map((e) => e.toString()).toList()
          : const [],
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.tryParse(json['last_seen_at'].toString())
          : null,
    );
  }
}
