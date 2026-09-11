import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';

import '../models/game_session.dart';
import '../models/game_state.dart';
import 'bot_controller.dart';
import 'game_service.dart';

/// Wraps [GameService] + [FirebaseAuth] behind the [GameSession] interface.
///
/// Online play continues to use Firestore exactly as before — this adapter
/// simply lets the shared UI screens accept any backend via the abstraction.
class OnlineGameSession implements GameSession {
  final String gameId;
  final GameService _svc;
  late final String _uid;
  int? _mySeat;

  BotController? _botController;

  OnlineGameSession({required this.gameId, GameService? service})
      : _svc = service ?? GameService() {
    _uid = FirebaseAuth.instance.currentUser!.uid;
  }

  @override
  String get myUid => _uid;

  @override
  int? get mySeat => _mySeat;

  @override
  Stream<GameState> get gameStream => _svc.gameStream(gameId);

  @override
  Stream<List<String>> get handStream => _svc.handStream(gameId, _uid);

  /// Lazily create and return the bot controller for this game.
  /// Only the host needs this; other players get null.
  BotController? get botController => _botController;

  /// Called by the UI when a new game state arrives. Seeds bot hands when
  /// a new round starts and forwards state to the bot controller.
  void onGameStateChanged(GameState game) {
    // Lazily create bot controller when host has bots
    if (game.hostId == _uid && game.players.any((p) => p.isBot)) {
      _botController ??= BotController(_svc, gameId);
      // Seed cached hands when a new round starts
      if (_svc.lastDealtHands != null) {
        _botController!.seedHands(_svc.lastDealtHands!, game);
        _svc.lastDealtHands = null;
      }
    }
    _botController?.onGameStateChanged(game);

    // Cache my seat from game state
    _mySeat = game.seatForUid(_uid)?.seat;
  }

  @override
  Future<void> playCard(int seat, String cardId) =>
      _svc.playCard(gameId, _uid, seat, cardId);

  @override
  void resolveTrick() => _svc.resolveTrick(gameId);

  @override
  void claimRemaining(int seat) =>
      _svc.claimRemaining(gameId, _uid, seat);

  @override
  void confirmNextGame(String uid, int seat) =>
      _svc.confirmNextGame(gameId, uid, seat: seat);

  @override
  void startNextGame({required String hostUid}) =>
      _svc.startNextGame(gameId, hostUid);

  @override
  void publishFinalHands(String uid) =>
      _svc.publishFinalHands(gameId, uid);

  @override
  void dispose() {
    _botController?.dispose();
    _botController = null;
  }
}
