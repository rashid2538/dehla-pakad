import 'package:flutter/foundation.dart';

import '../models/game_state.dart';
import '../models/player.dart';
import 'bot_engine.dart';
import 'game_service.dart';

class BotController {
  final GameService _gameService;
  final String gameId;
  final BotMemory _memory = BotMemory();

  /// Local hand cache — keyed by bot uid. Avoids Firestore reads.
  final Map<String, List<String>> _botHands = {};

  GameState? _latestState;
  bool _processing = false;
  bool _disposed = false;
  bool _stateChangedWhileProcessing = false;
  int _lastObservedTrick = 0;
  int _lastObservedPlayCount = 0;

  static const _botPlayDelay = Duration(milliseconds: 400);

  BotController(this._gameService, this.gameId);

  void seedHands(Map<String, List<String>> allHands, GameState state) {
    _botHands.clear();
    for (final p in state.players) {
      if (p.isBot && allHands.containsKey(p.uid)) {
        _botHands[p.uid] = List<String>.from(allHands[p.uid]!);
      }
    }
  }

  void onGameStateChanged(GameState state) {
    _updateMemory(state);
    _latestState = state;
    if (_processing) {
      _stateChangedWhileProcessing = true;
    } else {
      _maybeAct();
    }
  }

  void _updateMemory(GameState state) {
    if (state.trickNumber < _lastObservedTrick ||
        (state.trickNumber == 1 && _lastObservedTrick > 1)) {
      _memory.reset();
      _lastObservedTrick = 0;
      _lastObservedPlayCount = 0;
    }

    final trick = state.currentTrick;
    if (trick == null) return;

    if (state.trickNumber > _lastObservedTrick) {
      _lastObservedTrick = state.trickNumber;
      _lastObservedPlayCount = 0;
    }

    final plays = trick.plays;
    final leadSuit = plays.isNotEmpty ? plays.first.card.suit : null;
    for (var i = _lastObservedPlayCount; i < plays.length; i++) {
      final p = plays[i];
      final alreadyRecorded = _memory.allPlayedCardIds.contains(p.card.id);
      if (!alreadyRecorded) {
        _memory.recordPlay(p.seat, p.card, leadSuit);
      }
    }
    _lastObservedPlayCount = plays.length;
  }

  Future<void> _maybeAct() async {
    if (_processing || _disposed) return;

    final state = _latestState;
    if (state == null || state.status != GameStatus.inProgress) return;

    final seat = state.currentTurnSeat;
    if (seat == null) return;
    final player = state.seats[seat];
    if (player == null || !player.isBot) return;

    _processing = true;
    try {
      await _playBotSequence();
    } finally {
      _processing = false;
      if (!_disposed && _stateChangedWhileProcessing) {
        _stateChangedWhileProcessing = false;
        _maybeAct();
      }
    }
  }

  Future<void> _playBotSequence() async {
    while (!_disposed) {
      final state = _latestState;
      if (state == null || state.status != GameStatus.inProgress) return;

      final seat = state.currentTurnSeat;
      if (seat == null) return;
      final player = state.seats[seat];
      if (player == null || !player.isBot) return;

      // Use cached hand — fall back to Firestore if cache miss
      var hand = _botHands[player.uid];
      if (hand == null || hand.isEmpty) {
        hand = await _gameService.getBotHand(gameId, player.uid);
        if (hand.isEmpty || _disposed) return;
        _botHands[player.uid] = List<String>.from(hand);
      }

      debugPrint(
        'Bot ${player.displayName} (seat $seat, '
        '${player.botDifficulty?.name ?? "medium"}) '
        'playing from ${hand.length} cards',
      );

      final cardId = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: seat,
        difficulty: player.botDifficulty ?? BotDifficulty.medium,
        memory: _memory,
      );

      debugPrint('Bot chose: $cardId');

      try {
        await _gameService.playCard(gameId, player.uid, seat, cardId);
      } catch (e) {
        debugPrint('BotController ERROR: $e');
        return;
      }

      // Remove played card from local cache
      _botHands[player.uid]?.remove(cardId);

      // If 4th card in trick, stop — resolve runs from UI side
      final playCount = (state.currentTrick?.plays.length ?? 0) + 1;
      if (playCount >= 4) return;

      // If next seat is also a bot, loop with a short visual delay
      final nextSeat = GameState.nextSeat(seat);
      final nextPlayer = state.seats[nextSeat];
      if (nextPlayer == null || !nextPlayer.isBot) return;

      await Future.delayed(_botPlayDelay);
      if (_disposed) return;

      // Re-read game state (single read, not waiting for listener round-trip)
      final freshState = await _gameService.getGame(gameId);
      if (freshState == null || _disposed) return;
      _updateMemory(freshState);
      _latestState = freshState;
    }
  }

  void dispose() {
    _disposed = true;
  }
}
