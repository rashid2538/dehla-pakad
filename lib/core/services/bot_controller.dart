import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/game_state.dart';
import '../models/player.dart';
import 'bot_engine.dart';
import 'game_service.dart';

class BotController {
  final GameService _gameService;
  final String gameId;
  final BotMemory _memory = BotMemory();

  GameState? _latestState;
  bool _processing = false;
  bool _disposed = false;
  bool _stateChangedWhileProcessing = false;
  int _lastObservedTrick = 0;
  int _lastObservedPlayCount = 0;

  BotController(this._gameService, this.gameId);

  void onGameStateChanged(GameState state) {
    _updateMemory(state);
    _latestState = state;
    if (_processing) {
      _stateChangedWhileProcessing = true;
    } else {
      _maybeAct();
    }
  }

  /// Track plays as they happen to build void-suit inference (§3.3).
  void _updateMemory(GameState state) {
    // New game — reset memory
    if (state.trickNumber < _lastObservedTrick ||
        (state.trickNumber == 1 && _lastObservedTrick > 1)) {
      _memory.reset();
      _lastObservedTrick = 0;
      _lastObservedPlayCount = 0;
    }

    final trick = state.currentTrick;
    if (trick == null) return;

    // Trick number advanced — reset play counter for new trick
    if (state.trickNumber > _lastObservedTrick) {
      _lastObservedTrick = state.trickNumber;
      _lastObservedPlayCount = 0;
    }

    // Record any new plays we haven't seen yet
    final plays = trick.plays;
    final leadSuit = plays.isNotEmpty ? plays.first.card.suit : null;
    for (var i = _lastObservedPlayCount; i < plays.length; i++) {
      final p = plays[i];
      final alreadyRecorded =
          _memory.allPlayedCardIds.contains(p.card.id);
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
      if (_disposed) return;

      final freshState = _latestState;
      if (freshState == null ||
          freshState.status != GameStatus.inProgress) {
        return;
      }
      final freshSeat = freshState.currentTurnSeat;
      if (freshSeat == null) return;
      final freshPlayer = freshState.seats[freshSeat];
      if (freshPlayer == null || !freshPlayer.isBot) return;

      final hand = await _gameService.getBotHand(gameId, freshPlayer.uid);
      if (hand.isEmpty || _disposed) return;

      debugPrint(
        'Bot ${freshPlayer.displayName} (seat $freshSeat, '
        '${freshPlayer.botDifficulty?.name ?? "medium"}) '
        'playing from ${hand.length} cards',
      );

      final cardId = chooseBotCard(
        hand: hand,
        gameState: freshState,
        botSeat: freshSeat,
        difficulty: freshPlayer.botDifficulty ?? BotDifficulty.medium,
        memory: _memory,
      );

      debugPrint('Bot chose: $cardId');

      await _gameService.playCard(
        gameId,
        freshPlayer.uid,
        freshSeat,
        cardId,
      );
    } on FirebaseException catch (e) {
      debugPrint('BotController Firebase error: [${e.code}] ${e.message}');
    } catch (e) {
      debugPrint('BotController ERROR: $e');
    } finally {
      _processing = false;
      if (!_disposed && _stateChangedWhileProcessing) {
        _stateChangedWhileProcessing = false;
        _maybeAct();
      }
    }
  }

  void dispose() {
    _disposed = true;
  }
}
