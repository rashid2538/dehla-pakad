import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/game_session.dart';
import '../models/game_state.dart';
import '../models/player.dart';
import '../models/playing_card.dart';
import '../utils/bot_names.dart';
import '../utils/card_rules.dart'
    show
        canClaimRemaining,
        dealCards,
        determineNextGameStarter,
        evaluateWinner,
        shuffleDeck,
        teamLabel,
        trickWinner,
        unseenCards;
import 'bot_engine.dart';

/// In-memory game session for offline "Play vs Bots" mode.
///
/// No Firestore, no auth, no network. Owns all five pieces of state described
/// in the design doc and emits the same [GameState] model the shared UI
/// expects.
class LocalGameSession implements GameSession {
  @override
  final String myUid;
  @override
  final int mySeat;

  final String playerName;
  final BotDifficulty difficulty;

  GameState? _game;
  final Map<int, List<PlayingCard>> _hands = {};
  final Map<String, List<PlayingCard>> _dealtHands = {};
  final BotMemory _memory = BotMemory();

  final Map<int, String> _seatUidMap = {};
  final List<String> _botUids = [];
  final Random _rng = Random.secure();

  late final StreamController<GameState> _gameController =
      StreamController<GameState>.broadcast();
  late final StreamController<List<String>> _handController =
      StreamController<List<String>>.broadcast();

  List<String>? _lastHand;

  /// SharedPreferences key holding the serialized session for resume-after-
  /// restart. Versioned so future format changes can safely invalidate it.
  static const savedGameKey = 'local_game_save_v1';
  static const _saveVersion = 1;

  int _saveToken = 0;
  bool _completionCleared = false;

  /// Stream of game state. Every subscription replays the latest snapshot
  /// first, so late subscribers (e.g. the result screen, which subscribes
  /// while the table screen is still tearing down) always see the current
  /// game instead of hanging on a loading indicator.
  @override
  Stream<GameState> get gameStream async* {
    final game = _game;
    if (game != null) yield game;
    yield* _gameController.stream;
  }

  @override
  Stream<List<String>> get handStream async* {
    final hand = _lastHand;
    if (hand != null) yield hand;
    yield* _handController.stream;
  }

  Timer? _botTimer;
  bool _disposed = false;
  bool _resolvingTrick = false;

  // ── Previous game context for next-game starter logic ──
  int? _prevTrumpSetterSeat;
  String? _prevTrumpTeam;
  String? _prevWinningTeam;

  LocalGameSession({
    required this.myUid,
    required this.mySeat,
    required this.playerName,
    this.difficulty = BotDifficulty.medium,
  });

  // ── Lifecycle ──

  /// Set up 4 seats (me + 3 bots), shuffle, deal, emit initial state.
  void start() {
    final usedNames = <String>{playerName};
    _seatUidMap[mySeat] = myUid;

    final botSeats = [1, 2, 3, 4].where((s) => s != mySeat).toList();
    for (final seat in botSeats) {
      final uid = 'local_bot_$seat';
      final name = pickBotName(usedNames);
      usedNames.add(name);
      _seatUidMap[seat] = uid;
      _botUids.add(uid);
    }

    final deck = shuffleDeck();
    final dealt = dealCards(deck, _rng.nextInt(4) + 1);
    final startingSeat = _rng.nextInt(4) + 1;

    // Populate hands
    for (final entry in dealt.entries) {
      final uid = _seatUidMap[entry.key]!;
      _hands[entry.key] = entry.value;
      _dealtHands[uid] = List.of(entry.value);
    }

    // Build seats
    final seats = <int, PlayerSeat?>{};
    for (int i = 1; i <= 4; i++) {
      final uid = _seatUidMap[i]!;
      final isBot = uid.startsWith('local_bot_');
      seats[i] = PlayerSeat(
        uid: uid,
        displayName: isBot ? pickBotName(usedNames) : playerName,
        seat: i,
        isBot: isBot,
        ready: true,
        connected: true,
        botDifficulty: isBot ? difficulty : null,
      );
    }

    _game = GameState(
      gameId: 'local',
      status: GameStatus.inProgress,
      roomCode: 'LOCAL',
      hostId: myUid,
      seats: seats,
      startingPlayerSeat: startingSeat,
      currentTurnSeat: startingSeat,
      trickNumber: 1,
      currentTrick: CurrentTrick(leaderSeat: startingSeat),
    );

    _emitState();
    _emitHand();
    _maybeScheduleBot();
  }

  // ── Card play ──

  @override
  Future<void> playCard(int seat, String cardId) async {
    final game = _game;
    if (game == null) throw Exception('Game not started');
    if (game.status != GameStatus.inProgress) {
      throw Exception('Game is not active');
    }
    if (game.currentTurnSeat != seat) throw Exception('Not your turn');

    final hand = _hands[seat];
    if (hand == null || !hand.any((c) => c.id == cardId)) {
      throw Exception('Card not in hand');
    }

    final trick = game.currentTrick;
    if (trick == null) throw Exception('No active trick');

    final card = PlayingCard.fromId(cardId);
    final isFirstPlay = trick.plays.isEmpty;
    final leadSuit = isFirstPlay ? null : game.leadSuit;

    // Follow-suit check
    if (leadSuit != null) {
      final hasLeadSuit = hand.any((c) => c.suit == leadSuit);
      if (hasLeadSuit && card.suit != leadSuit) {
        throw Exception('Must follow suit');
      }
    }

    // Commit
    hand.removeWhere((c) => c.id == cardId);

    final newPlays = [
      ...trick.plays,
      TrickPlay(seat, card, DateTime.now()),
    ];

    // Trump establishment: first off-suit play in the game
    Suit? newTrumpSuit = game.trumpSuit;
    String? newTrumpTeam = game.trumpTeam;
    int? newTrumpSetterSeat = game.trumpSetterSeat;
    if (game.trumpSuit == null && leadSuit != null && card.suit != leadSuit) {
      newTrumpSuit = card.suit;
      newTrumpTeam = GameState.teamForSeat(seat);
      newTrumpSetterSeat = seat;
    }

    Suit? newLeadSuit = game.leadSuit;
    if (isFirstPlay) newLeadSuit = card.suit;

    final playCount = trick.plays.length + 1;
    final newTrick = CurrentTrick(
      leaderSeat: trick.leaderSeat,
      plays: newPlays,
    );

    _game = game.copyWith(
      leadSuit: isFirstPlay ? card.suit : newLeadSuit,
      trumpSuit: newTrumpSuit,
      trumpTeam: newTrumpTeam,
      trumpSetterSeat: newTrumpSetterSeat,
      currentTrick: newTrick,
      currentTurnSeat: playCount == 4 ? null : GameState.nextSeat(seat),
    );

    // Update the human's hand — never broadcast a bot seat's hand, otherwise
    // the shared handStream would render another player's cards as our own.
    _emitHand();

    _emitState();

    if (playCount == 4) {
      _scheduleResolveTrick();
    } else {
      _maybeScheduleBot();
    }
  }

  @override
  void resolveTrick() => _resolveTrickNow();

  @override
  void claimRemaining(int seat) {
    final game = _game;
    if (game == null) return;
    if (game.status != GameStatus.inProgress) return;
    if (game.currentTurnSeat != seat) return;
    if (game.currentTrick == null || game.currentTrick!.plays.isNotEmpty) return;

    final hand = _hands[seat];
    if (hand == null || hand.isEmpty) return;

    if (!canClaimRemaining(
      hand: hand,
      unseen: unseenCards(game, hand),
      trump: game.trumpSuit,
    )) {
      return;
    }

    final team = GameState.teamForSeat(seat);
    final remainingTricks =
        13 - game.trickPileA.trickCount - game.trickPileB.trickCount;

    // Every remaining trick and uncollected 10 goes to this team.
    final tens = Map<String, String?>.from(game.collectedTens.tens);
    for (final entry in tens.entries) {
      if (entry.value == null) tens[entry.key] = team;
    }

    final isTeamA = team == 'teamA';
    final trickCounts = {
      'teamA': game.trickPileA.trickCount + (isTeamA ? remainingTricks : 0),
      'teamB': game.trickPileB.trickCount + (isTeamA ? 0 : remainingTricks),
    };

    final outcome =
        evaluateWinner(collectedTens: tens, trickCounts: trickCounts);
    final winningTeam = outcome.team;
    if (winningTeam == null) return;

    final tensForWinner = tens.values.where((t) => t == winningTeam).length;
    final allFourTens = tensForWinner == 4;

    VictoryType victoryType;
    if (allFourTens) {
      final trumpTeam = game.trumpTeam;
      victoryType = (trumpTeam != null && trumpTeam == winningTeam)
          ? VictoryType.court
          : VictoryType.poopy;
    } else {
      victoryType = VictoryType.victory;
    }

    final pile = isTeamA ? game.trickPileA : game.trickPileB;

    _game = game.copyWith(
      collectedTens: CollectedTens(tens: tens),
      trickPileA: isTeamA
          ? TrickPile(
              trickCount: pile.trickCount + remainingTricks,
              cards: [...pile.cards, ...hand.map((c) => c.id)],
            )
          : game.trickPileA,
      trickPileB: !isTeamA
          ? TrickPile(
              trickCount: pile.trickCount + remainingTricks,
              cards: [...pile.cards, ...hand.map((c) => c.id)],
            )
          : game.trickPileB,
      status: GameStatus.completed,
      winningTeam: winningTeam,
      victoryType: victoryType,
      endReason: _buildClaimReason(
          game, seat, hand.length, remainingTricks, tens, outcome.reason),
      currentTurnSeat: null,
    );

    // Auto-confirm bots
    _autoConfirmBots();
    _prevTrumpSetterSeat = game.trumpSetterSeat;
    _prevTrumpTeam = game.trumpTeam;
    _prevWinningTeam = winningTeam;

    _emitState();
  }

  // ── Next game ──

  @override
  void confirmNextGame(String uid, int seat) {
    final game = _game;
    if (game == null || game.status != GameStatus.completed) return;
    _game = game.copyWith(
      seats: {
        for (final e in game.seats.entries)
          e.key: e.value?.copyWith(
            ready: e.value?.uid == uid ? true : e.value?.ready,
          ),
      },
    );
    _emitState();
  }

  @override
  void startNextGame({required String hostUid}) {
    final game = _game;
    if (game == null || game.status != GameStatus.completed) return;
    if (!game.allReady) return;

    // Determine starter
    int starterSeat;
    if (_prevTrumpSetterSeat != null &&
        _prevTrumpTeam != null &&
        _prevWinningTeam != null) {
      starterSeat = determineNextGameStarter(
        trumpSetterSeat: _prevTrumpSetterSeat!,
        trumpTeam: _prevTrumpTeam!,
        winningTeam: _prevWinningTeam!,
      );
    } else {
      starterSeat = _rng.nextInt(4) + 1;
    }

    // Shuffle and deal
    final deck = shuffleDeck();
    final dealt = dealCards(deck, starterSeat);

    _hands.clear();
    _dealtHands.clear();
    _memory.reset();

    for (final entry in dealt.entries) {
      final uid = _seatUidMap[entry.key]!;
      _hands[entry.key] = entry.value;
      _dealtHands[uid] = List.of(entry.value);
    }

    // Reset ready flags
    final seats = <int, PlayerSeat?>{};
    for (int i = 1; i <= 4; i++) {
      final old = game.seats[i];
      seats[i] = old?.copyWith(ready: false);
    }

    _game = game.copyWith(
      status: GameStatus.inProgress,
      seats: seats,
      startingPlayerSeat: starterSeat,
      currentTurnSeat: starterSeat,
      leadSuit: null,
      trumpSuit: null,
      trumpTeam: null,
      trumpSetterSeat: null,
      trickNumber: 1,
      currentTrick: CurrentTrick(leaderSeat: starterSeat),
      collectedTens: const CollectedTens(),
      trickPileA: const TrickPile(),
      trickPileB: const TrickPile(),
      winningTeam: null,
      victoryType: null,
      endReason: null,
      finalHands: {},
      previousTrumpSetterSeat: _prevTrumpSetterSeat,
      previousVictoryType: _game?.victoryType,
      previousWinningTeam: _prevWinningTeam,
      previousTrumpTeam: _prevTrumpTeam,
    );

    _emitState();
    _emitHand();
    _maybeScheduleBot();
  }

  @override
  void publishFinalHands(String uid) {
    final game = _game;
    if (game == null || game.status != GameStatus.completed) return;

    final finalHands = <int, List<String>>{};
    for (int seat = 1; seat <= 4; seat++) {
      final seatUid = _seatUidMap[seat];
      if (seatUid == null) continue;
      final dealt = _dealtHands[seatUid];
      if (dealt != null) {
        finalHands[seat] = dealt.map((c) => c.id).toList();
      }
    }

    _game = game.copyWith(finalHands: finalHands);
    _emitState();
  }

  @override
  void dispose() {
    _disposed = true;
    _botTimer?.cancel();
    _gameController.close();
    _handController.close();
  }

  // ── Internal ──

  List<String> _handIds(int seat) =>
      (_hands[seat] ?? []).map((c) => c.id).toList();

  void _emitState() {
    if (!_disposed && _game != null) {
      _gameController.add(_game!);
    }
    _syncPersistence();
  }

  void _emitHand() {
    _lastHand = _handIds(mySeat);
    if (!_disposed) {
      _handController.add(_lastHand!);
    }
  }

  // ── Persistence ──

  /// Restart bot scheduling for a freshly-restored session. Safe to call
  /// multiple times; no-ops when it isn't a bot's turn. Also re-arms the
  /// resolve-trick timer if the app was killed mid-resolution (4th card played,
  /// winner not yet computed).
  void resume() {
    final game = _game;
    if (game != null && game.status == GameStatus.inProgress) {
      final trick = game.currentTrick;
      if (game.currentTurnSeat == null &&
          trick != null &&
          trick.plays.length == 4) {
        _scheduleResolveTrick();
        return;
      }
    }
    _maybeScheduleBot();
  }

  /// Serialize the full session (public state + private hands + bot memory)
  /// into a plain JSON-serializable map for [SharedPreferences].
  Map<String, dynamic> toSavedGame() => {
        'version': _saveVersion,
        'playerName': playerName,
        'difficulty': difficulty.name,
        'playerUid': myUid,
        'mySeat': mySeat,
        'seatUids': {
          for (final e in _seatUidMap.entries) '${e.key}': e.value,
        },
        'prevTrumpSetterSeat': _prevTrumpSetterSeat,
        'prevTrumpTeam': _prevTrumpTeam,
        'prevWinningTeam': _prevWinningTeam,
        'game': _encodeGame(_game),
        'hands': {
          for (final e in _hands.entries)
            '${e.key}': e.value.map((c) => c.id).toList(),
        },
        'dealtHands': {
          for (final e in _dealtHands.entries)
            e.key: e.value.map((c) => c.id).toList(),
        },
        'botMemory': {
          'knownVoidSuits': {
            for (final e in _memory.knownVoidSuits.entries)
              '${e.key}': e.value.map((s) => s.letter).toList(),
          },
          'playHistory': [
            for (final p in _memory.playHistory)
              {'seat': p.seat, 'card': p.card.id},
          ],
        },
      };

  /// Rebuild a fully-resumable session from [toSavedGame]. Returns null if the
  /// map is corrupt or from an incompatible save version.
  static LocalGameSession? fromSavedGame(Map<String, dynamic> json) {
    if (json['version'] != _saveVersion) return null;
    final gameMap = json['game'] as Map<String, dynamic>?;
    if (gameMap == null) return null;

    final mySeat = json['mySeat'] as int? ?? 1;
    final session = LocalGameSession(
      myUid: json['playerUid'] as String? ?? 'local_human',
      mySeat: mySeat,
      playerName: json['playerName'] as String? ?? 'You',
      difficulty: BotDifficulty.fromString(json['difficulty'] as String?),
    );

    session._seatUidMap.clear();
    final seatUids = (json['seatUids'] as Map<String, dynamic>? ?? {});
    for (final e in seatUids.entries) {
      final seat = int.tryParse(e.key);
      if (seat != null) session._seatUidMap[seat] = e.value as String;
    }
    session._botUids.clear();
    session._botUids.addAll(
        session._seatUidMap.values.where((u) => u.startsWith('local_bot_')));

    session._prevTrumpSetterSeat = json['prevTrumpSetterSeat'] as int?;
    session._prevTrumpTeam = json['prevTrumpTeam'] as String?;
    session._prevWinningTeam = json['prevWinningTeam'] as String?;

    session._game = _decodeGame(gameMap);

    session._hands.clear();
    final hands = (json['hands'] as Map<String, dynamic>? ?? {});
    for (final e in hands.entries) {
      final seat = int.tryParse(e.key);
      if (seat == null) continue;
      session._hands[seat] = (e.value as List<dynamic>? ?? [])
          .cast<String>()
          .map(PlayingCard.fromId)
          .toList();
    }

    session._dealtHands.clear();
    final dealt = (json['dealtHands'] as Map<String, dynamic>? ?? {});
    for (final e in dealt.entries) {
      session._dealtHands[e.key] = (e.value as List<dynamic>? ?? [])
          .cast<String>()
          .map(PlayingCard.fromId)
          .toList();
    }

    final mem = (json['botMemory'] as Map<String, dynamic>? ?? {});
    session._memory.reset();
    final voids = (mem['knownVoidSuits'] as Map<String, dynamic>? ?? {});
    for (final e in voids.entries) {
      final seat = int.tryParse(e.key);
      if (seat == null) continue;
      session._memory.knownVoidSuits[seat] = {
        for (final s in (e.value as List<dynamic>? ?? []))
          Suit.fromLetter(s as String),
      };
    }
    for (final p in (mem['playHistory'] as List<dynamic>? ?? [])) {
      final rec = p as Map<String, dynamic>;
      session._memory.playHistory.add((
        seat: rec['seat'] as int,
        card: PlayingCard.fromId(rec['card'] as String),
      ));
    }

    session._lastHand = session._handIds(mySeat);
    return session;
  }

  /// Fire-and-forget write of the current state. A monotonically increasing
  /// token discards superseded writes, so a quick burst never leaves stale
  /// data on disk.
  void _persist() {
    if (_disposed) return;
    final token = ++_saveToken;
    final json = jsonEncode(toSavedGame());
    unawaited(SharedPreferences.getInstance().then((prefs) async {
      if (token != _saveToken || _disposed) return;
      await prefs.setString(savedGameKey, json);
    }));
  }

  /// Removes the resume save. In-flight writes are invalidated by bumping the
  /// token before the remove is applied.
  Future<void> clearSavedGame() async {
    _saveToken++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(savedGameKey);
  }

  /// Persist the current state / drop the save when the round ends. Called
  /// from [_emitState] after every mutation.
  void _syncPersistence() {
    if (_disposed) return;
    final game = _game;
    if (game == null) return;

    if (game.status == GameStatus.completed) {
      if (!_completionCleared) {
        _completionCleared = true;
        unawaited(clearSavedGame());
      }
      return;
    }
    _completionCleared = false;
    _persist();
  }

  void _maybeScheduleBot() {
    if (_disposed) return;
    final game = _game;
    if (game == null || game.status != GameStatus.inProgress) return;
    final seat = game.currentTurnSeat;
    if (seat == null) return;
    final player = game.seats[seat];
    if (player == null || !player.isBot) return;

    _botTimer?.cancel();
    _botTimer = Timer(const Duration(milliseconds: 500), () {
      if (!_disposed) _playBotTurn(seat);
    });
  }

  void _playBotTurn(int seat) {
    if (_disposed) return;
    final game = _game;
    if (game == null || game.status != GameStatus.inProgress) return;
    if (game.currentTurnSeat != seat) return;

    final player = game.seats[seat];
    if (player == null || !player.isBot) return;

    final hand = _hands[seat];
    if (hand == null || hand.isEmpty) return;

    // Check claim remaining on lead
    if (game.currentTrick?.plays.isEmpty ?? false) {
      if (canClaimRemaining(
        hand: hand,
        unseen: unseenCards(game, hand),
        trump: game.trumpSuit,
      )) {
        claimRemaining(seat);
        return;
      }
    }

    final cardId = chooseBotCard(
      hand: hand.map((c) => c.id).toList(),
      gameState: game,
      botSeat: seat,
      difficulty: player.botDifficulty ?? BotDifficulty.medium,
      memory: _memory,
    );

    playCard(seat, cardId);
  }

  void _scheduleResolveTrick() {
    if (_resolvingTrick) return;
    _resolvingTrick = true;
    Timer(const Duration(milliseconds: 600), () {
      _resolvingTrick = false;
      if (!_disposed) _resolveTrickNow();
    });
  }

  void _resolveTrickNow() {
    final game = _game;
    if (game == null) return;
    if (game.status != GameStatus.inProgress) return;
    final trick = game.currentTrick;
    if (trick == null || trick.plays.length != 4) return;
    if (game.currentTurnSeat != null) return; // already resolved

    final leadSuit = game.leadSuit!;
    final trumpSuit = game.trumpSuit;

    // Find winner
    final winnerPlay = trickWinner(trick.plays, leadSuit, trumpSuit);
    final winnerSeat = winnerPlay.seat;
    final winnerTeam = GameState.teamForSeat(winnerSeat);

    // Collect cards
    final allCards = trick.plays.map((p) => p.card.id).toList();
    final isTeamA = winnerTeam == 'teamA';
    final currentPile = isTeamA ? game.trickPileA : game.trickPileB;

    // Track tens
    final tens = Map<String, String?>.from(game.collectedTens.tens);
    for (final play in trick.plays) {
      if (play.card.isTen) {
        tens[play.card.id] = winnerTeam;
      }
    }

    final collectedTens = CollectedTens(tens: tens);
    final teamATens = collectedTens.tensForTeam('teamA');
    final teamBTens = collectedTens.tensForTeam('teamB');

    final newTrickCountA =
        isTeamA ? currentPile.trickCount + 1 : game.trickPileA.trickCount;
    final newTrickCountB =
        !isTeamA ? currentPile.trickCount + 1 : game.trickPileB.trickCount;

    final outcome = evaluateWinner(
      collectedTens: tens,
      trickCounts: {'teamA': newTrickCountA, 'teamB': newTrickCountB},
    );

    // Record plays in memory
    for (final play in trick.plays) {
      if (!_memory.allPlayedCardIds.contains(play.card.id)) {
        _memory.recordPlay(play.seat, play.card, leadSuit);
      }
    }

    if (outcome.team != null) {
      final winningTeam = outcome.team!;
      final allFourTens =
          winningTeam == 'teamA' ? teamATens == 4 : teamBTens == 4;

      VictoryType victoryType;
      if (allFourTens) {
        final trumpTeam = game.trumpTeam;
        victoryType = (trumpTeam != null && trumpTeam == winningTeam)
            ? VictoryType.court
            : VictoryType.poopy;
      } else {
        victoryType = VictoryType.victory;
      }

      _game = game.copyWith(
        collectedTens: collectedTens,
        trickPileA: TrickPile(
          trickCount: newTrickCountA,
          cards: [
            ...game.trickPileA.cards,
            ...allCards,
          ],
        ),
        trickPileB: TrickPile(
          trickCount: newTrickCountB,
          cards: [
            ...game.trickPileB.cards,
          ],
        ),
        status: GameStatus.completed,
        winningTeam: winningTeam,
        victoryType: victoryType,
        endReason: outcome.reason,
        currentTurnSeat: null,
      );

      _autoConfirmBots();
      _prevTrumpSetterSeat = game.trumpSetterSeat;
      _prevTrumpTeam = game.trumpTeam;
      _prevWinningTeam = winningTeam;
    } else {
      // Next trick
      _game = game.copyWith(
        collectedTens: collectedTens,
        trickPileA: TrickPile(
          trickCount: newTrickCountA,
          cards: [
            ...game.trickPileA.cards,
            ...allCards,
          ],
        ),
        trickPileB: TrickPile(
          trickCount: newTrickCountB,
          cards: [
            ...game.trickPileB.cards,
          ],
        ),
        trickNumber: game.trickNumber + 1,
        currentTurnSeat: winnerSeat,
        leadSuit: null,
        currentTrick: CurrentTrick(leaderSeat: winnerSeat),
      );
    }

    _emitState();
    _maybeScheduleBot();
  }

  void _autoConfirmBots() {
    final game = _game;
    if (game == null) return;
    _game = game.copyWith(
      seats: {
        for (final e in game.seats.entries)
          e.key: e.value?.copyWith(
            ready: e.value?.isBot == true ? true : e.value?.ready,
          ),
      },
    );
  }

  String _buildClaimReason(
    GameState game,
    int seat,
    int cards,
    int tricks,
    Map<String, String?> tens,
    String? outcomeReason,
  ) {
    final name = game.seats[seat]?.displayName ?? 'The leader';
    final team = teamLabel(GameState.teamForSeat(seat));
    final trump = game.trumpSuit?.symbol ?? '';
    final unclaimedTens =
        tens.entries.where((e) => e.value == null).length;
    final tensPart = unclaimedTens == 0
        ? ''
        : ' and the last ${unclaimedTens == 1 ? "10" : "$unclaimedTens 10s"}';
    return '$name was on lead holding '
        '$cards unbeatable '
        '${cards == 1 ? "card" : "cards"} (trump $trump) — nobody could take a '
        'trick back, so the remaining $tricks '
        '${tricks == 1 ? "trick" : "tricks"}$tensPart went to $team. '
        '${outcomeReason ?? ''}'
        .trim();
  }
}

/// Helper to create the seat→uid map for local mode.
Map<int, String> buildLocalSeatUids(int mySeat) {
  final map = <int, String>{};
  map[mySeat] = 'local_human';
  for (int i = 1; i <= 4; i++) {
    if (i != mySeat) map[i] = 'local_bot_$i';
  }
  return map;
}

/// Plain-JSON encoding of [GameState] (no Firestore types, safe for
/// shared_preferences). Symmetric with [_decodeGame].
Map<String, dynamic>? _encodeGame(GameState? game) {
  if (game == null) return null;
  return {
    'status': game.status.name,
    'roomCode': game.roomCode,
    'hostId': game.hostId,
    'seats': {
      for (final e in game.seats.entries) '${e.key}': e.value?.toMap(),
    },
    'startingPlayerSeat': game.startingPlayerSeat,
    'currentTurnSeat': game.currentTurnSeat,
    'leadSuit': game.leadSuit?.letter,
    'trumpSuit': game.trumpSuit?.letter,
    'trumpTeam': game.trumpTeam,
    'trumpSetterSeat': game.trumpSetterSeat,
    'trickNumber': game.trickNumber,
    'currentTrick': game.currentTrick == null
        ? null
        : {
            'leaderSeat': game.currentTrick!.leaderSeat,
            'plays': [
              for (final p in game.currentTrick!.plays)
                {
                  'seat': p.seat,
                  'card': p.card.id,
                  if (p.playedAt != null)
                    'playedAt': p.playedAt!.millisecondsSinceEpoch,
                },
            ],
          },
    'collectedTens': game.collectedTens.toMap(),
    'trickPileA': game.trickPileA.toMap(),
    'trickPileB': game.trickPileB.toMap(),
    'winningTeam': game.winningTeam,
    'victoryType': game.victoryType?.name,
    'endReason': game.endReason,
    'finalHands': {
      for (final e in game.finalHands.entries) '${e.key}': e.value,
    },
    'previousTrumpSetterSeat': game.previousTrumpSetterSeat,
    'previousVictoryType': game.previousVictoryType?.name,
    'previousWinningTeam': game.previousWinningTeam,
    'previousTrumpTeam': game.previousTrumpTeam,
  };
}

GameState _decodeGame(Map<String, dynamic> m) {
  final seatsMap = m['seats'] as Map<String, dynamic>? ?? {};
  final currentTrickMap = m['currentTrick'] as Map<String, dynamic>?;
  return GameState(
    gameId: 'local',
    status: GameStatus.fromString(m['status'] as String? ?? 'inProgress'),
    roomCode: m['roomCode'] as String? ?? 'LOCAL',
    hostId: m['hostId'] as String? ?? 'local_human',
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
    currentTrick: currentTrickMap == null
        ? null
        : CurrentTrick(
            leaderSeat: currentTrickMap['leaderSeat'] as int,
            plays: [
              for (final p
                  in (currentTrickMap['plays'] as List<dynamic>? ?? []))
                TrickPlay(
                  (p as Map<String, dynamic>)['seat'] as int,
                  PlayingCard.fromId(p['card'] as String),
                  p['playedAt'] != null
                      ? DateTime.fromMillisecondsSinceEpoch(
                          p['playedAt'] as int)
                      : null,
                ),
            ],
          ),
    collectedTens: CollectedTens.fromMap(
        m['collectedTens'] as Map<String, dynamic>?),
    trickPileA: TrickPile.fromMap(m['trickPileA'] as Map<String, dynamic>?),
    trickPileB: TrickPile.fromMap(m['trickPileB'] as Map<String, dynamic>?),
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
  );
}
