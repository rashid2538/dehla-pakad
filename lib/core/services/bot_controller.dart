import 'dart:math';

import '../models/game_state.dart';
import 'bot_engine.dart';
import 'game_service.dart';

class BotController {
  final GameService _gameService;
  final String gameId;
  final _rng = Random();

  GameState? _latestState;
  bool _processing = false;
  bool _disposed = false;

  BotController(this._gameService, this.gameId);

  void onGameStateChanged(GameState state) {
    _latestState = state;
    _maybeAct();
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
      await Future.delayed(
        Duration(milliseconds: 800 + _rng.nextInt(1000)),
      );
      if (_disposed) return;

      final hand = await _gameService.getBotHand(gameId, player.uid);
      if (hand.isEmpty || _disposed) return;

      final cardId = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: seat,
      );

      await _gameService.playCard(gameId, player.uid, seat, cardId);
    } catch (_) {
      // Retried on next _maybeAct cycle
    } finally {
      _processing = false;
      if (!_disposed) _maybeAct();
    }
  }

  void dispose() {
    _disposed = true;
  }
}
