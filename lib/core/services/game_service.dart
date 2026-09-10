import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/game_state.dart';
import '../models/player.dart';
import '../models/playing_card.dart';
import '../utils/card_rules.dart'
    show canClaimRemaining, evaluateWinner, teamLabel, unseenCards;
import '../utils/bot_names.dart';

final gameServiceProvider = Provider((ref) => GameService());

class GameService {
  final _firestore = FirebaseFirestore.instance;
  static const _uuid = Uuid();
  static final _rng = Random.secure();

  /// Cached hands from the last deal — consumed by BotController.
  Map<String, List<String>>? lastDealtHands;

  // ── Streams ──

  Stream<GameState> gameStream(String gameId) => _firestore
      .doc('games/$gameId')
      .snapshots()
      .map((s) => GameState.fromFirestore(s.data()!, gameId));

  Stream<List<String>> handStream(String gameId, String uid) => _firestore
      .doc('games/$gameId/privateHands/$uid')
      .snapshots()
      .map((s) => (s.data()?['cards'] as List<dynamic>?)?.cast<String>() ?? []);

  Future<GameState?> getGame(String gameId) async {
    final snap = await _firestore.doc('games/$gameId').get();
    if (!snap.exists) return null;
    return GameState.fromFirestore(snap.data()!, gameId);
  }

  // ── Lobby ──

  Future<String> createRoom(
    String hostUid,
    String displayName, {
    String? customCode,
    String? photoUrl,
  }) async {
    final gameId = _uuid.v4();
    final roomCode = customCode?.toUpperCase() ?? _generateRoomCode();

    // ponytail: no uniqueness check on room codes; collision odds ≈ 0 for 36^6.
    // Add a query check if rooms start colliding.
    await _firestore.doc('games/$gameId').set(GameState(
      gameId: gameId,
      status: GameStatus.lobby,
      roomCode: roomCode,
      hostId: hostUid,
      seats: {
        1: PlayerSeat(
          uid: hostUid,
          displayName: displayName,
          photoUrl: photoUrl,
          seat: 1,
          ready: false,
          connected: true,
        ),
        2: null,
        3: null,
        4: null,
      },
    ).toFirestore());

    return gameId;
  }

  Future<String> joinRoom(
    String roomCode,
    String uid,
    String displayName, {
    String? photoUrl,
  }) async {
    final query = await _firestore
        .collection('games')
        .where('roomCode', isEqualTo: roomCode.toUpperCase())
        .where('status', isEqualTo: 'lobby')
        .limit(1)
        .get();

    if (query.docs.isEmpty) throw Exception('Room not found');
    final doc = query.docs.first;
    final gameId = doc.id;

    return _firestore.runTransaction<String>((tx) async {
      final snap = await tx.get(doc.reference);
      final game = GameState.fromFirestore(snap.data()!, gameId);

      // Already in room → reconnect
      final existing = game.seatForUid(uid);
      if (existing != null) return gameId;

      if (game.playerCount >= 4) throw Exception('Room is full');

      final openSeat =
          [1, 2, 3, 4].firstWhere((s) => game.seats[s] == null);

      tx.update(doc.reference, {
        'seats.$openSeat': PlayerSeat(
          uid: uid,
          displayName: displayName,
          photoUrl: photoUrl,
          seat: openSeat,
          connected: true,
        ).toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      return gameId;
    });
  }

  Future<void> leaveRoom(String gameId, String uid) async {
    final ref = _firestore.doc('games/$gameId');

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);
      if (game.status != GameStatus.lobby) return;

      final player = game.seatForUid(uid);
      if (player == null) return;

      final updates = <String, dynamic>{
        'seats.${player.seat}': null,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Host transfer — skip bots
      if (game.hostId == uid) {
        final nextHuman = game.players
            .where((p) => p.uid != uid && !p.isBot)
            .toList();
        if (nextHuman.isEmpty) {
          updates['status'] = 'abandoned';
        } else {
          updates['hostId'] = nextHuman.first.uid;
        }
      }

      tx.update(ref, updates);
    });
  }

  Future<void> toggleReady(String gameId, String uid,
      {required int seat, required bool currentlyReady}) async {
    await _firestore.doc('games/$gameId').update({
      'seats.$seat.ready': !currentlyReady,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> kickPlayer(String gameId, String hostUid, int seat) async {
    final ref = _firestore.doc('games/$gameId');
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);
      if (game.hostId != hostUid) return;
      if (game.status != GameStatus.lobby && game.status != GameStatus.completed) return;
      tx.update(ref, {
        'seats.$seat': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> swapSeats(String gameId, String hostUid, int seat1, int seat2) async {
    final ref = _firestore.doc('games/$gameId');
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);
      if (game.hostId != hostUid) return;
      if (game.status != GameStatus.lobby) return;

      final p1 = game.seats[seat1];
      final p2 = game.seats[seat2];
      if (p1 == null && p2 == null) return;

      tx.update(ref, {
        'seats.$seat1': p2?.copyWith(seat: seat1).toMap(),
        'seats.$seat2': p1?.copyWith(seat: seat2).toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  // ── Bot Management ──

  Future<void> addBot(
    String gameId,
    String hostUid, {
    required int seat,
    required Set<String> usedNames,
    BotDifficulty difficulty = BotDifficulty.medium,
  }) async {
    final botName = pickBotName(usedNames);
    final botUid = 'bot_${_uuid.v4()}';

    await _firestore.doc('games/$gameId').update({
      'seats.$seat': PlayerSeat(
        uid: botUid,
        displayName: botName,
        seat: seat,
        isBot: true,
        ready: true,
        connected: true,
        botDifficulty: difficulty,
      ).toMap(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Reads one private hand. Rules allow the owner (any uid) and the host
  /// (bot hands only).
  /// [dealt] returns the hand as dealt (kept for the result screen) instead of
  /// the cards still unplayed. Falls back to the live hand for games dealt
  /// before 'dealt' was recorded.
  Future<List<String>> readHand(String gameId, String uid,
      {bool dealt = false}) async {
    final data = await _firestore
        .doc('games/$gameId/privateHands/$uid')
        .get()
        .then((d) => d.data());
    final key = dealt && data?['dealt'] != null ? 'dealt' : 'cards';
    return (data?[key] as List<dynamic>?)?.cast<String>() ?? [];
  }

  // ── Player Name Update ──

  Future<void> updatePlayerName(
      String gameId, String uid, String newName) async {
    final ref = _firestore.doc('games/$gameId');
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);
      final player = game.seatForUid(uid);
      if (player == null) return;
      tx.update(ref, {
        'seats.${player.seat}.displayName': newName,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  // ── Start Game & Deal ──

  Future<void> startGame(String gameId, String hostUid) async {
    final ref = _firestore.doc('games/$gameId');

    Map<String, List<String>>? dealtHands;

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);

      if (game.hostId != hostUid) throw Exception('Not the host');
      if (!game.allReady) throw Exception('Not all players are ready');
      if (game.status != GameStatus.lobby) throw Exception('Game not in lobby');

      final deck = PlayingCard.fullDeck..shuffle(_rng);
      final startingSeat = _rng.nextInt(4) + 1;

      // Round-robin deal
      final hands = <String, List<String>>{};
      for (final p in game.players) {
        hands[p.uid] = [];
      }

      final seatOrder = List.generate(
        4,
        (i) => ((startingSeat - 1 + i) % 4) + 1,
      );

      for (var i = 0; i < 52; i++) {
        final seat = seatOrder[i % 4];
        final player = game.seats[seat]!;
        hands[player.uid]!.add(deck[i].id);
      }

      // Write hands
      for (final entry in hands.entries) {
        tx.set(
          _firestore.doc('games/$gameId/privateHands/${entry.key}'),
          {'cards': entry.value, 'dealt': entry.value},
        );
      }

      // Reset ready flags + update game state
      final seatUpdates = <String, dynamic>{};
      for (final p in game.players) {
        seatUpdates['seats.${p.seat}.ready'] = false;
      }

      tx.update(ref, {
        ...seatUpdates,
        'status': GameStatus.inProgress.name,
        'startingPlayerSeat': startingSeat,
        'currentTurnSeat': startingSeat,
        'leadSuit': null,
        'trumpSuit': null,
        'trumpTeam': null,
        'trumpSetterSeat': null,
        'trickNumber': 1,
        'currentTrick': CurrentTrick(leaderSeat: startingSeat).toMap(),
        'collectedTens': const CollectedTens().toMap(),
        'trickPileA': const TrickPile().toMap(),
        'trickPileB': const TrickPile().toMap(),
        'winningTeam': null,
        'victoryType': null,
        'endReason': null,
        'finalHands': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      dealtHands = hands;
    });

    lastDealtHands = dealtHands;
  }

  // ── Play Card ──

  Future<void> playCard(
    String gameId,
    String uid,
    int seat,
    String cardId,
  ) async {
    final gameRef = _firestore.doc('games/$gameId');
    final handRef = _firestore.doc('games/$gameId/privateHands/$uid');

    await _firestore.runTransaction((tx) async {
      final gameSnap = await tx.get(gameRef);
      final handSnap = await tx.get(handRef);

      final game = GameState.fromFirestore(gameSnap.data()!, gameId);
      final hand = (handSnap.data()?['cards'] as List<dynamic>?)
              ?.cast<String>() ?? [];

      // Validate
      if (game.status != GameStatus.inProgress) {
        throw Exception('Game is not active');
      }
      if (game.currentTurnSeat != seat) throw Exception('Not your turn');
      if (!hand.contains(cardId)) throw Exception('Card not in hand');
      if (game.currentTrick == null) throw Exception('No active trick');

      final card = PlayingCard.fromId(cardId);
      final trick = game.currentTrick!;
      final isFirstPlay = trick.plays.isEmpty;
      final leadSuit = isFirstPlay ? null : game.leadSuit;

      // Follow-suit check
      if (leadSuit != null) {
        final hasLeadSuit = hand.any(
          (c) => PlayingCard.fromId(c).suit == leadSuit,
        );
        if (hasLeadSuit && card.suit != leadSuit) {
          throw Exception('Must follow suit');
        }
      }

      // Remove card from hand
      final newHand = List<String>.from(hand)..remove(cardId);
      tx.update(handRef, {'cards': newHand});

      // Build updates
      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // Build play list
      final newPlays = [
        ...trick.plays.map((p) => p.toMap()),
        TrickPlay(seat, card, DateTime.now()).toMap(),
      ];

      // Set lead suit on first play
      if (isFirstPlay) {
        updates['leadSuit'] = card.suit.letter;
      }

      // Trump establishment: first off-suit play in the game
      if (game.trumpSuit == null && leadSuit != null && card.suit != leadSuit) {
        updates['trumpSuit'] = card.suit.letter;
        updates['trumpTeam'] = GameState.teamForSeat(seat);
        updates['trumpSetterSeat'] = seat;
      }

      final playCount = trick.plays.length + 1;

      updates['currentTrick.plays'] = newPlays;
      if (playCount == 4) {
        // Mark trick as pending resolution (null turn = no one can play)
        updates['currentTurnSeat'] = null;
      } else {
        updates['currentTurnSeat'] = GameState.nextSeat(seat);
      }

      tx.update(gameRef, updates);
    });
  }

  Future<void> resolveTrick(String gameId) async {
    final ref = _firestore.doc('games/$gameId');
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);
      if (game.status != GameStatus.inProgress) return;
      final trick = game.currentTrick;
      if (trick == null || trick.plays.length != 4) return;
      // Already resolved (currentTurnSeat set by another client)
      if (game.currentTurnSeat != null) return;

      final updates = <String, dynamic>{
        'updatedAt': FieldValue.serverTimestamp(),
      };
      _resolveTrick(game, trick.plays.map((p) => p.toMap()).toList(),
          trick.plays.last.card, trick.plays.last.seat, updates);
      tx.update(ref, updates);
    });
  }

  void _resolveTrick(
    GameState game,
    List<Map<String, dynamic>> playsData,
    PlayingCard lastCard,
    int lastSeat,
    Map<String, dynamic> updates,
  ) {
    final plays = playsData
        .map((p) => TrickPlay.fromMap(p))
        .toList();

    // Determine trump suit (could have been set this trick)
    final trumpSuitLetter = updates['trumpSuit'] as String? ??
        game.trumpSuit?.letter;
    final trumpSuit = trumpSuitLetter != null
        ? Suit.fromLetter(trumpSuitLetter)
        : null;
    final leadSuit = Suit.fromLetter(
      updates['leadSuit'] as String? ?? game.leadSuit!.letter,
    );

    // Find winner
    final winnerPlay = _findTrickWinner(plays, leadSuit, trumpSuit);
    final winnerSeat = winnerPlay.seat;
    final winnerTeam = GameState.teamForSeat(winnerSeat);

    // Collect cards
    final allCards = plays.map((p) => p.card.id).toList();
    final isTeamA = winnerTeam == 'teamA';
    final pileKey = isTeamA ? 'trickPileA' : 'trickPileB';
    final currentPile = isTeamA ? game.trickPileA : game.trickPileB;

    updates[pileKey] = TrickPile(
      trickCount: currentPile.trickCount + 1,
      cards: [...currentPile.cards, ...allCards],
    ).toMap();

    // Track tens
    final tensUpdates = Map<String, String?>.from(game.collectedTens.tens);
    for (final play in plays) {
      if (play.card.isTen) {
        tensUpdates[play.card.id] = winnerTeam;
      }
    }
    updates['collectedTens'] = Map<String, dynamic>.from(tensUpdates);

    // Check victory: all 4 tens to one team
    final collectedTens = CollectedTens(tens: tensUpdates);
    final teamATens = collectedTens.tensForTeam('teamA');
    final teamBTens = collectedTens.tensForTeam('teamB');

    final newTrickCountA = isTeamA
        ? currentPile.trickCount + 1
        : game.trickPileA.trickCount;
    final newTrickCountB = !isTeamA
        ? currentPile.trickCount + 1
        : game.trickPileB.trickCount;

    /* 
     * Deterministic game-over decision (shared with card_rules.dart):
     *   - all 4 tens to one team
     *   - 3+ tens vs fewer tens
     *   - 2-2 tens with a team at 7+ tricks
     *   - all 13 tricks played
     */
    final outcome = evaluateWinner(
      collectedTens: tensUpdates,
      trickCounts: {'teamA': newTrickCountA, 'teamB': newTrickCountB},
    );
    final winningTeam = outcome.team;

    if (winningTeam != null) {
      updates['endReason'] = outcome.reason;
      final allFourTens = winningTeam == 'teamA'
          ? teamATens == 4
          : teamBTens == 4;
      _setVictory(updates, winningTeam, game, updates,
          allFourTens: allFourTens);
      updates['status'] = GameStatus.completed.name;
      // Auto-confirm bots for next game
      for (final p in game.players) {
        if (p.isBot) updates['seats.${p.seat}.ready'] = true;
      }
    } else {
      // Next trick
      updates['trickNumber'] = game.trickNumber + 1;
      updates['currentTurnSeat'] = winnerSeat;
      updates['leadSuit'] = null;
      updates['currentTrick'] = CurrentTrick(leaderSeat: winnerSeat).toMap();
    }
  }

  void _setVictory(
    Map<String, dynamic> updates,
    String winnerTeam,
    GameState game,
    Map<String, dynamic> allUpdates, {
    bool allFourTens = false,
  }) {
    updates['winningTeam'] = winnerTeam;
    if (!allFourTens) {
      // 3-1 tens or 2-2 with more tricks → normal victory
      updates['victoryType'] = VictoryType.victory.name;
    } else {
      // All 4 tens: court if trump-setter's team, poopy otherwise
      final trumpTeam = allUpdates['trumpTeam'] as String? ?? game.trumpTeam;
      updates['victoryType'] = (trumpTeam != null && trumpTeam == winnerTeam)
          ? VictoryType.court.name
          : VictoryType.poopy.name;
    }
  }

  TrickPlay _findTrickWinner(
    List<TrickPlay> plays,
    Suit leadSuit,
    Suit? trumpSuit,
  ) {
    final trumpPlays = trumpSuit != null
        ? plays.where((p) => p.card.suit == trumpSuit).toList()
        : <TrickPlay>[];

    if (trumpPlays.isNotEmpty) {
      return trumpPlays.reduce(
        (a, b) => a.card.rank.value >= b.card.rank.value ? a : b,
      );
    }

    final leadPlays = plays.where((p) => p.card.suit == leadSuit).toList();
    return leadPlays.reduce(
      (a, b) => a.card.rank.value >= b.card.rank.value ? a : b,
    );
  }

  /// Ends the game when the player on lead provably wins every remaining
  /// trick (see [canClaimRemaining]). All remaining tricks and every
  /// uncollected 10 go to their team — playing them out cannot change a thing.
  ///
  /// A no-op unless the claim still holds against the state read inside the
  /// transaction, so a stale client can't cut a live game short.
  Future<void> claimRemaining(String gameId, String uid, int seat) async {
    final gameRef = _firestore.doc('games/$gameId');
    final handRef = _firestore.doc('games/$gameId/privateHands/$uid');

    await _firestore.runTransaction((tx) async {
      final gameSnap = await tx.get(gameRef);
      final handSnap = await tx.get(handRef);
      final game = GameState.fromFirestore(gameSnap.data()!, gameId);
      final handIds =
          (handSnap.data()?['cards'] as List<dynamic>?)?.cast<String>() ?? [];

      if (game.status != GameStatus.inProgress) return;
      if (game.currentTurnSeat != seat) return;
      // Must be on lead — a claim mid-trick isn't safe to evaluate.
      if (game.currentTrick == null || game.currentTrick!.plays.isNotEmpty) {
        return;
      }

      final hand = handIds.map(PlayingCard.fromId).toList();
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

      // Every remaining trick — and so every uncollected 10 — goes to [team].
      final tens = Map<String, String?>.from(game.collectedTens.tens);
      final unclaimedTens =
          tens.entries.where((e) => e.value == null).map((e) => e.key).toList();
      for (final id in unclaimedTens) {
        tens[id] = team;
      }

      final isTeamA = team == 'teamA';
      final trickCounts = {
        'teamA': game.trickPileA.trickCount + (isTeamA ? remainingTricks : 0),
        'teamB': game.trickPileB.trickCount + (isTeamA ? 0 : remainingTricks),
      };

      final outcome =
          evaluateWinner(collectedTens: tens, trickCounts: trickCounts);
      final winningTeam = outcome.team;
      if (winningTeam == null) return; // defensive: shouldn't happen

      final pileKey = isTeamA ? 'trickPileA' : 'trickPileB';
      final pile = isTeamA ? game.trickPileA : game.trickPileB;

      final updates = <String, dynamic>{
        'collectedTens': Map<String, dynamic>.from(tens),
        pileKey: TrickPile(
          trickCount: pile.trickCount + remainingTricks,
          cards: [...pile.cards, ...handIds],
        ).toMap(),
        'status': GameStatus.completed.name,
        'currentTurnSeat': null,
        'endReason': _claimReason(game, seat, hand.length, remainingTricks,
            unclaimedTens.length, outcome.reason),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final tensForWinner =
          tens.values.where((t) => t == winningTeam).length;
      _setVictory(updates, winningTeam, game, updates,
          allFourTens: tensForWinner == 4);

      for (final p in game.players) {
        if (p.isBot) updates['seats.${p.seat}.ready'] = true;
      }

      tx.update(gameRef, updates);
    });
  }

  String _claimReason(GameState game, int seat, int cards, int tricks,
      int tens, String? outcomeReason) {
    final name = game.seats[seat]?.displayName ?? 'The leader';
    final team = teamLabel(GameState.teamForSeat(seat));
    final trump = game.trumpSuit?.symbol ?? '';
    final tensPart = tens == 0
        ? ''
        : ' and the last ${tens == 1 ? "10" : "$tens 10s"}';
    return "$name was on lead holding $cards unbeatable "
        "${cards == 1 ? "card" : "cards"} (trump $trump) — nobody could take a "
        "trick back, so the remaining $tricks "
        "${tricks == 1 ? "trick" : "tricks"}$tensPart went to $team. "
        "${outcomeReason ?? ''}"
        .trim();
  }

  /// After a game ends, publishes this player's dealt hand (and every bot's,
  /// if we're the host) so the result screen can show all four hands. Which of
  /// those cards were actually played is already public, in the trick piles.
  /// Each client publishes only what it is allowed to read.
  Future<void> publishFinalHands(String gameId, String uid) async {
    final game = await getGame(gameId);
    if (game == null || game.status != GameStatus.completed) return;
    final me = game.seatForUid(uid);
    if (me == null) return;

    final updates = <String, dynamic>{
      'finalHands.${me.seat}': await readHand(gameId, uid, dealt: true),
    };
    if (game.hostId == uid) {
      for (final p in game.players.where((p) => p.isBot)) {
        updates['finalHands.${p.seat}'] =
            await readHand(gameId, p.uid, dealt: true);
      }
    }
    await _firestore.doc('games/$gameId').update(updates);
  }

  // ── Next Game ──

  Future<void> confirmNextGame(String gameId, String uid,
      {required int seat}) async {
    await _firestore.doc('games/$gameId').update({
      'seats.$seat.ready': true,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> startNextGame(String gameId, String hostUid) async {
    final ref = _firestore.doc('games/$gameId');
    Map<String, List<String>>? dealtHands;

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);

      if (game.hostId != hostUid) throw Exception('Not the host');
      if (game.status != GameStatus.completed) {
        throw Exception('Game not completed');
      }
      if (!game.allReady) throw Exception('Not all confirmed');

      // Determine starter for next game
      final starterSeat = _nextGameStarter(game);

      final deck = PlayingCard.fullDeck..shuffle(_rng);
      final hands = <String, List<String>>{};
      for (final p in game.players) {
        hands[p.uid] = [];
      }

      final seatOrder = List.generate(
        4,
        (i) => ((starterSeat - 1 + i) % 4) + 1,
      );
      for (var i = 0; i < 52; i++) {
        final seat = seatOrder[i % 4];
        final player = game.seats[seat]!;
        hands[player.uid]!.add(deck[i].id);
      }

      for (final entry in hands.entries) {
        tx.set(
          _firestore.doc('games/$gameId/privateHands/${entry.key}'),
          {'cards': entry.value, 'dealt': entry.value},
        );
      }

      final seatUpdates = <String, dynamic>{};
      for (final p in game.players) {
        seatUpdates['seats.${p.seat}.ready'] = false;
      }

      tx.update(ref, {
        ...seatUpdates,
        'status': GameStatus.inProgress.name,
        'startingPlayerSeat': starterSeat,
        'currentTurnSeat': starterSeat,
        'leadSuit': null,
        'trumpSuit': null,
        'trumpTeam': null,
        'trumpSetterSeat': null,
        'trickNumber': 1,
        'currentTrick': CurrentTrick(leaderSeat: starterSeat).toMap(),
        'collectedTens': const CollectedTens().toMap(),
        'trickPileA': const TrickPile().toMap(),
        'trickPileB': const TrickPile().toMap(),
        'winningTeam': null,
        'victoryType': null,
        'endReason': null,
        'finalHands': null,
        'previousTrumpSetterSeat': game.trumpSetterSeat,
        'previousVictoryType': game.victoryType?.name,
        'previousWinningTeam': game.winningTeam,
        'previousTrumpTeam': game.trumpTeam,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      dealtHands = hands;
    });

    lastDealtHands = dealtHands;
  }

  int _nextGameStarter(GameState game) {
    final trumpSetterSeat = game.trumpSetterSeat;
    if (trumpSetterSeat == null) return _rng.nextInt(4) + 1;

    final trumpTeam = game.trumpTeam;
    final winningTeam = game.winningTeam;

    if (trumpTeam == winningTeam) {
      // Trump-setting team won → partner of trump-setter leads
      return GameState.partnerSeat(trumpSetterSeat);
    } else {
      // Trump-setting team lost → next clockwise opponent from trump-setter
      var next = GameState.nextSeat(trumpSetterSeat);
      while (GameState.teamForSeat(next) == trumpTeam) {
        next = GameState.nextSeat(next);
      }
      return next;
    }
  }

  // ── Room Management ──

  Stream<List<GameState>> myRoomsStream(String uid) => _firestore
      .collection('games')
      .where('hostId', isEqualTo: uid)
      .orderBy('updatedAt', descending: true)
      .limit(20)
      .snapshots()
      .map((snap) => snap.docs
          .map((d) => GameState.fromFirestore(d.data(), d.id))
          .where((g) => g.status != GameStatus.abandoned)
          .toList());

  Future<void> deleteRoom(String gameId, String hostUid) async {
    final ref = _firestore.doc('games/$gameId');
    final snap = await ref.get();
    if (!snap.exists) return;
    final game = GameState.fromFirestore(snap.data()!, gameId);
    if (game.hostId != hostUid) throw Exception('Not the host');

    // Delete known player hands, then the game doc
    final batch = _firestore.batch();
    for (final p in game.players) {
      batch.delete(_firestore.doc('games/$gameId/privateHands/${p.uid}'));
    }
    batch.delete(ref);
    await batch.commit();
  }

  Future<void> renameRoom(String gameId, String hostUid, String newCode) async {
    final ref = _firestore.doc('games/$gameId');
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);
      if (game.hostId != hostUid) throw Exception('Not the host');
      tx.update(ref, {
        'roomCode': newCode.toUpperCase(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> resetToLobby(String gameId, String hostUid) async {
    final ref = _firestore.doc('games/$gameId');
    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final game = GameState.fromFirestore(snap.data()!, gameId);
      if (game.hostId != hostUid) throw Exception('Not the host');

      final seatUpdates = <String, dynamic>{};
      for (final p in game.players) {
        seatUpdates['seats.${p.seat}.ready'] = false;
      }

      tx.update(ref, {
        ...seatUpdates,
        'status': GameStatus.lobby.name,
        'startingPlayerSeat': null,
        'currentTurnSeat': null,
        'leadSuit': null,
        'trumpSuit': null,
        'trumpTeam': null,
        'trumpSetterSeat': null,
        'trickNumber': 1,
        'currentTrick': null,
        'collectedTens': const CollectedTens().toMap(),
        'trickPileA': const TrickPile().toMap(),
        'trickPileB': const TrickPile().toMap(),
        'winningTeam': null,
        'victoryType': null,
        'endReason': null,
        'finalHands': null,
        'previousTrumpSetterSeat': null,
        'previousVictoryType': null,
        'previousWinningTeam': null,
        'previousTrumpTeam': null,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  // ── Utils ──

  String _generateRoomCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return String.fromCharCodes(
      List.generate(6, (_) => chars.codeUnitAt(_rng.nextInt(chars.length))),
    );
  }
}
