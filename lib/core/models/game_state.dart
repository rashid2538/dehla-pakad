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

class TeamStats {
  final int wins;
  final int losses;
  final int courtWins;
  final int poopyWins;

  const TeamStats({
    this.wins = 0,
    this.losses = 0,
    this.courtWins = 0,
    this.poopyWins = 0,
  });

  TeamStats copyWith({
    int? wins,
    int? losses,
    int? courtWins,
    int? poopyWins,
  }) =>
      TeamStats(
        wins: wins ?? this.wins,
        losses: losses ?? this.losses,
        courtWins: courtWins ?? this.courtWins,
        poopyWins: poopyWins ?? this.poopyWins,
      );

  TeamStats applyResult({required bool won, required VictoryType? type}) =>
      copyWith(
        wins: won ? wins + 1 : wins,
        losses: won ? losses : losses + 1,
        courtWins: won && type == VictoryType.court ? courtWins + 1 : courtWins,
        poopyWins: won && type == VictoryType.poopy ? poopyWins + 1 : poopyWins,
      );

  Map<String, dynamic> toMap() => {
        'wins': wins,
        'losses': losses,
        'courtWins': courtWins,
        'poopyWins': poopyWins,
      };

  factory TeamStats.fromMap(Map<String, dynamic>? m) => TeamStats(
        wins: m?['wins'] as int? ?? 0,
        losses: m?['losses'] as int? ?? 0,
        courtWins: m?['courtWins'] as int? ?? 0,
        poopyWins: m?['poopyWins'] as int? ?? 0,
      );
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
  /// Human-readable explanation of how the game ended. Written once, at the
  /// moment the game is marked completed.
  final String? endReason;
  /// Remaining cards per seat, published by each client after the game ends
  /// so the result screen can show every hand. Empty during play.
  final Map<int, List<String>> finalHands;
  final int? previousTrumpSetterSeat;
  final VictoryType? previousVictoryType;
  final String? previousWinningTeam;
  final String? previousTrumpTeam;
  final Map<String, TeamStats> teamStats;
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
    this.endReason,
    this.finalHands = const {},
    this.previousTrumpSetterSeat,
    this.previousVictoryType,
    this.previousWinningTeam,
    this.previousTrumpTeam,
    this.teamStats = const {'teamA': TeamStats(), 'teamB': TeamStats()},
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

  /// Sentinel used by [copyWith]: omitting a nullable argument keeps the
  /// current value, while passing `null` explicitly clears it (e.g. the 4th
  /// play of a trick clears [currentTurnSeat], or a new round clears trump).
  static const Object _unset = Object();

  GameState copyWith({
    String? gameId,
    GameStatus? status,
    String? roomCode,
    String? hostId,
    Map<int, PlayerSeat?>? seats,
    Object? startingPlayerSeat = _unset,
    Object? currentTurnSeat = _unset,
    Object? leadSuit = _unset,
    Object? trumpSuit = _unset,
    Object? trumpTeam = _unset,
    Object? trumpSetterSeat = _unset,
    int? trickNumber,
    Object? currentTrick = _unset,
    CollectedTens? collectedTens,
    TrickPile? trickPileA,
    TrickPile? trickPileB,
    Object? winningTeam = _unset,
    Object? victoryType = _unset,
    Object? endReason = _unset,
    Map<int, List<String>>? finalHands,
    Object? previousTrumpSetterSeat = _unset,
    Object? previousVictoryType = _unset,
    Object? previousWinningTeam = _unset,
    Object? previousTrumpTeam = _unset,
    Map<String, TeamStats>? teamStats,
  }) {
    return GameState(
      gameId: gameId ?? this.gameId,
      status: status ?? this.status,
      roomCode: roomCode ?? this.roomCode,
      hostId: hostId ?? this.hostId,
      seats: seats ?? this.seats,
      teamStats: teamStats ?? this.teamStats,
      startingPlayerSeat: identical(startingPlayerSeat, _unset)
          ? this.startingPlayerSeat
          : startingPlayerSeat as int?,
      currentTurnSeat: identical(currentTurnSeat, _unset)
          ? this.currentTurnSeat
          : currentTurnSeat as int?,
      leadSuit:
          identical(leadSuit, _unset) ? this.leadSuit : leadSuit as Suit?,
      trumpSuit:
          identical(trumpSuit, _unset) ? this.trumpSuit : trumpSuit as Suit?,
      trumpTeam: identical(trumpTeam, _unset)
          ? this.trumpTeam
          : trumpTeam as String?,
      trumpSetterSeat: identical(trumpSetterSeat, _unset)
          ? this.trumpSetterSeat
          : trumpSetterSeat as int?,
      trickNumber: trickNumber ?? this.trickNumber,
      currentTrick: identical(currentTrick, _unset)
          ? this.currentTrick
          : currentTrick as CurrentTrick?,
      collectedTens: collectedTens ?? this.collectedTens,
      trickPileA: trickPileA ?? this.trickPileA,
      trickPileB: trickPileB ?? this.trickPileB,
      winningTeam: identical(winningTeam, _unset)
          ? this.winningTeam
          : winningTeam as String?,
      victoryType: identical(victoryType, _unset)
          ? this.victoryType
          : victoryType as VictoryType?,
      endReason: identical(endReason, _unset)
          ? this.endReason
          : endReason as String?,
      finalHands: finalHands ?? this.finalHands,
      previousTrumpSetterSeat: identical(previousTrumpSetterSeat, _unset)
          ? this.previousTrumpSetterSeat
          : previousTrumpSetterSeat as int?,
      previousVictoryType: identical(previousVictoryType, _unset)
          ? this.previousVictoryType
          : previousVictoryType as VictoryType?,
      previousWinningTeam: identical(previousWinningTeam, _unset)
          ? this.previousWinningTeam
          : previousWinningTeam as String?,
      previousTrumpTeam: identical(previousTrumpTeam, _unset)
          ? this.previousTrumpTeam
          : previousTrumpTeam as String?,
    );
  }

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
        'endReason': endReason,
        'previousTrumpSetterSeat': previousTrumpSetterSeat,
        'previousVictoryType': previousVictoryType?.name,
        'previousWinningTeam': previousWinningTeam,
        'previousTrumpTeam': previousTrumpTeam,
        'teamStats': {
          for (final e in teamStats.entries) e.key: e.value.toMap(),
        },
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
      endReason: m['endReason'] as String?,
      finalHands: {
        for (final e in (m['finalHands'] as Map<String, dynamic>? ?? {}).entries)
          if (int.tryParse(e.key) != null)
            int.parse(e.key): (e.value as List<dynamic>?)?.cast<String>() ?? [],
      },
      previousTrumpSetterSeat: m['previousTrumpSetterSeat'] as int?,
      previousVictoryType:
          VictoryType.fromString(m['previousVictoryType'] as String?),
      previousWinningTeam: m['previousWinningTeam'] as String?,
      previousTrumpTeam: m['previousTrumpTeam'] as String?,
      teamStats: _teamStatsFromMap(m['teamStats'] as Map<String, dynamic>?),
      updatedAt: (m['updatedAt'] as Timestamp?)?.toDate(),
    );
  }

  static Map<String, TeamStats> _teamStatsFromMap(
    Map<String, dynamic>? m,
  ) => {
        'teamA': TeamStats.fromMap(m?['teamA'] as Map<String, dynamic>?),
        'teamB': TeamStats.fromMap(m?['teamB'] as Map<String, dynamic>?),
      };
}
