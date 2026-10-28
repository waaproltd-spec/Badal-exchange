/// A betting-platform player, as the platform's cash register found them
/// ("Find a Player"). [name] is only ever what the platform said: null when
/// it gave none.
class PlayerLookup {
  const PlayerLookup({required this.found, required this.accountId, this.name});

  final bool found;
  final String accountId;
  final String? name;

  factory PlayerLookup.fromJson(Map<String, dynamic> json) => PlayerLookup(
        found: json['found'] == true,
        accountId: json['accountId'] as String? ?? '',
        name: (json['name'] as String?)?.trim().isEmpty ?? true ? null : (json['name'] as String).trim(),
      );
}
