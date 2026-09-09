class PlayerSeat {
  final String uid;
  final String displayName;
  final String? photoUrl;
  final bool connected;
  final bool ready;
  final int seat;
  final bool isBot;

  const PlayerSeat({
    required this.uid,
    required this.displayName,
    this.photoUrl,
    this.connected = true,
    this.ready = false,
    required this.seat,
    this.isBot = false,
  });

  PlayerSeat copyWith({
    String? displayName,
    String? photoUrl,
    bool? connected,
    bool? ready,
  }) =>
      PlayerSeat(
        uid: uid,
        displayName: displayName ?? this.displayName,
        photoUrl: photoUrl ?? this.photoUrl,
        connected: connected ?? this.connected,
        ready: ready ?? this.ready,
        seat: seat,
        isBot: isBot,
      );

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'displayName': displayName,
        'photoUrl': photoUrl,
        'connected': connected,
        'ready': ready,
        'seat': seat,
        'isBot': isBot,
      };

  factory PlayerSeat.fromMap(Map<String, dynamic> m, int seat) => PlayerSeat(
        uid: m['uid'] as String,
        displayName: m['displayName'] as String,
        photoUrl: m['photoUrl'] as String?,
        connected: m['connected'] as bool? ?? true,
        ready: m['ready'] as bool? ?? false,
        seat: seat,
        isBot: m['isBot'] as bool? ?? false,
      );
}
