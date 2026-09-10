enum BotDifficulty {
  easy,
  medium,
  hard;

  static BotDifficulty fromString(String? s) =>
      BotDifficulty.values.firstWhere((v) => v.name == s, orElse: () => medium);
}

class PlayerSeat {
  final String uid;
  final String displayName;
  final String? photoUrl;
  final bool connected;
  final bool ready;
  final int seat;
  final bool isBot;
  final BotDifficulty? botDifficulty;

  const PlayerSeat({
    required this.uid,
    required this.displayName,
    this.photoUrl,
    this.connected = true,
    this.ready = false,
    required this.seat,
    this.isBot = false,
    this.botDifficulty,
  });

  PlayerSeat copyWith({
    String? displayName,
    String? photoUrl,
    bool? connected,
    bool? ready,
    int? seat,
  }) =>
      PlayerSeat(
        uid: uid,
        displayName: displayName ?? this.displayName,
        photoUrl: photoUrl ?? this.photoUrl,
        connected: connected ?? this.connected,
        ready: ready ?? this.ready,
        seat: seat ?? this.seat,
        isBot: isBot,
        botDifficulty: botDifficulty,
      );

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'connected': connected,
        'ready': ready,
        'seat': seat,
        'isBot': isBot,
        if (botDifficulty != null) 'botDifficulty': botDifficulty!.name,
      };

  factory PlayerSeat.fromMap(Map<String, dynamic> m, int seat) => PlayerSeat(
        uid: m['uid'] as String,
        displayName: m['displayName'] as String,
        photoUrl: m['photoUrl'] as String?,
        connected: m['connected'] as bool? ?? true,
        ready: m['ready'] as bool? ?? false,
        seat: seat,
        isBot: m['isBot'] as bool? ?? false,
        botDifficulty: m['isBot'] == true
            ? BotDifficulty.fromString(m['botDifficulty'] as String?)
            : null,
      );
}
