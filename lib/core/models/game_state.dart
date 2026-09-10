import 'package:cloud_firestore/cloud_firestore.dart';

import 'playing_card.dart';
import 'player.dart';

enum GameStatus {
  lobby,
  dealing,
  inProgress,
  paused,
  completed,
  abandoned;

  static GameStatus fromString(String s) =>
      GameStatus.values.firstWhere((v) => v.name == s, orElse: () => lobby);
}

enum VictoryType {
  victory,
  court,
  poopy;

  static VictoryType? fromString(String? s) =>
      s == null ? null : VictoryType.values.firstWhere((v) => v.name == s,
          orElse: () => victory);
}

class TrickPlay {
  final int seat;
  final PlayingCard card;
  final DateTime? playedAt;

  const TrickPlay(this.seat, this.card, [this.playedAt]);

  Map<String, dynamic> toMap() => {
        'seat': seat,
        'card': card.id,
        if (playedAt != null) 'playedAt': Timestamp.fromDate(playedAt!),
      };

  factory TrickPlay.fromMap(Map<String, dynamic> m) => TrickPlay(
        m['seat'] as int,
        PlayingCard.fromId(m['card'] as String),
        (m['playedAt'] as Timestamp?)?.toDate(),
      );
}

class CurrentTrick {
  final int leaderSeat;
  final List<TrickPlay> plays;

  const CurrentTrick({required this.leaderSeat, this.plays = const []});

  bool get isComplete => plays.length == 4;

  Map<String, dynamic> toMap() => {
        'leaderSeat': leaderSeat,
        'plays': plays.map((p) => p.toMap()).toList(),
      };

  factory CurrentTrick.fromMap(Map<String, dynamic> m) => CurrentTrick(
        leaderSeat: m['leaderSeat'] as int,
        plays: (m['plays'] as List<dynamic>?)
                ?.map((p) => TrickPlay.fromMap(p as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

class CollectedTens {
  final Map<String, String?> tens;

  const CollectedTens({
    this.tens = const {'10S': null, '10H': null, '10D': null, '10C': null},
  });

  int tensForTeam(String team) =>
      tens.values.where((v) => v == team).length;

  bool allCollectedBy(String team) =>
      tens.values.every((v) => v == team);

  Map<String, dynamic> toMap() => Map<String, dynamic>.from(tens);

  factory CollectedTens.fromMap(Map<String, dynamic>? m) => CollectedTens(
        tens: {
          '10S': m?['10S'] as String?,
          '10H': m?['10H'] as String?,
          '10D': m?['10D'] as String?,
          '10C': m?['10C'] as String?,
        },
      );
}

class TrickPile {
  final int trickCount;
  final List<String> cards;

  const TrickPile({this.trickCount = 0, this.cards = const []});

  Map<String, dynamic> toMap() => {
        'trickCount': trickCount,
        'cards': cards,
      };

  factory TrickPile.fromMap(Map<String, dynamic>? m) => TrickPile(
        trickCount: m?['trickCount'] as int? ?? 0,
        cards: (m?['cards'] as List<dynamic>?)?.cast<String>() ?? [],
      );
}

class GameState {
  final String gameId;
  final GameStatus status;
  final String roomCode;
  final String hostId;
  final Map<int, PlayerSeat?> seats; // 1-4
  final int? startingPlayerSeat;
  final int? currentTurnSeat;
  final Suit? leadSuit;
  final Suit? trumpSuit;
  final String? trumpTeam;
  final int? trumpSetterSeat;
  final int trickNumber;
  final CurrentTrick? currentTrick;
  final CollectedTens collectedTens;
  final TrickPile trickPileA;
  final TrickPile trickPileB;
  final String? winningTeam;
  final VictoryType? victoryType;
  final int? previousTrumpSetterSeat;
  final VictoryType? previousVictoryType;
  final String? previousWinningTeam;
  final String? previousTrumpTeam;
  final DateTime? updatedAt;

  const GameState({
    required this.gameId,
    required this.status,
    required this.roomCode,
    required this.hostId,
    required this.seats,
    this.startingPlayerSeat,
    this.currentTurnSeat,
    this.leadSuit,
    this.trumpSuit,
    this.trumpTeam,
    this.trumpSetterSeat,
    this.trickNumber = 1,
    this.currentTrick,
    this.collectedTens = const CollectedTens(),
    this.trickPileA = const TrickPile(),
    this.trickPileB = const TrickPile(),
    this.winningTeam,
    this.victoryType,
    this.previousTrumpSetterSeat,
    this.previousVictoryType,
    this.previousWinningTeam,
    this.previousTrumpTeam,
    this.updatedAt,
  });

  static String teamForSeat(int seat) =>
      (seat == 1 || seat == 3) ? 'teamA' : 'teamB';

  static int partnerSeat(int seat) => seat <= 2 ? seat + 2 : seat - 2;

  static int nextSeat(int seat) => seat == 4 ? 1 : seat + 1;

  List<PlayerSeat> get players =>
      seats.values.whereType<PlayerSeat>().toList();

  int get playerCount => players.length;

  bool get allReady =>
      playerCount == 4 && players.every((p) => p.ready);

  PlayerSeat? seatForUid(String uid) =>
      players.where((p) => p.uid == uid).firstOrNull;

  Map<String, dynamic> toFirestore() => {
        'status': status.name,
        'roomCode': roomCode,
        'hostId': hostId,
        'seats': {
          for (final e in seats.entries)
            '${e.key}': e.value?.toMap(),
        },
        'startingPlayerSeat': startingPlayerSeat,
        'currentTurnSeat': currentTurnSeat,
        'leadSuit': leadSuit?.letter,
        'trumpSuit': trumpSuit?.letter,
        'trumpTeam': trumpTeam,
        'trumpSetterSeat': trumpSetterSeat,
        'trickNumber': trickNumber,
        'currentTrick': currentTrick?.toMap(),
        'collectedTens': collectedTens.toMap(),
        'trickPileA': trickPileA.toMap(),
        'trickPileB': trickPileB.toMap(),
        'winningTeam': winningTeam,
        'victoryType': victoryType?.name,
        'previousTrumpSetterSeat': previousTrumpSetterSeat,
        'previousVictoryType': previousVictoryType?.name,
        'previousWinningTeam': previousWinningTeam,
        'previousTrumpTeam': previousTrumpTeam,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  factory GameState.fromFirestore(Map<String, dynamic> m, String gameId) {
    final seatsMap = m['seats'] as Map<String, dynamic>? ?? {};
    return GameState(
      gameId: gameId,
      status: GameStatus.fromString(m['status'] as String? ?? 'lobby'),
      roomCode: m['roomCode'] as String? ?? '',
      hostId: m['hostId'] as String? ?? '',
      seats: {
        for (int i = 1; i <= 4; i++)
          i: seatsMap['$i'] != null
              ? PlayerSeat.fromMap(seatsMap['$i'] as Map<String, dynamic>, i)
              : null,
      },
      startingPlayerSeat: m['startingPlayerSeat'] as int?,
      currentTurnSeat: m['currentTurnSeat'] as int?,
      leadSuit: m['leadSuit'] != null
          ? Suit.fromLetter(m['leadSuit'] as String)
          : null,
      trumpSuit: m['trumpSuit'] != null
          ? Suit.fromLetter(m['trumpSuit'] as String)
          : null,
      trumpTeam: m['trumpTeam'] as String?,
      trumpSetterSeat: m['trumpSetterSeat'] as int?,
      trickNumber: m['trickNumber'] as int? ?? 1,
      currentTrick: m['currentTrick'] != null
          ? CurrentTrick.fromMap(m['currentTrick'] as Map<String, dynamic>)
          : null,
      collectedTens: CollectedTens.fromMap(
          m['collectedTens'] as Map<String, dynamic>?),
      trickPileA:
          TrickPile.fromMap(m['trickPileA'] as Map<String, dynamic>?),
      trickPileB:
          TrickPile.fromMap(m['trickPileB'] as Map<String, dynamic>?),
      winningTeam: m['winningTeam'] as String?,
      victoryType: VictoryType.fromString(m['victoryType'] as String?),
      previousTrumpSetterSeat: m['previousTrumpSetterSeat'] as int?,
      previousVictoryType:
          VictoryType.fromString(m['previousVictoryType'] as String?),
      previousWinningTeam: m['previousWinningTeam'] as String?,
      previousTrumpTeam: m['previousTrumpTeam'] as String?,
      updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
