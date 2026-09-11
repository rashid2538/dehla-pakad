import 'dart:async';

import '../models/game_state.dart';

/// Everything the shared game UI needs, regardless of backend.
///
/// [OnlineGameSession] wraps Firebase; [LocalGameSession] runs in-memory.
abstract class GameSession {
  /// The UID used to identify "me" in seat lookups.
  String get myUid;

  /// My seat number (1-4), or null before the game starts.
  int? get mySeat;

  /// Stream of game state snapshots (mirrors Firestore snapshots online,
  /// or in-memory broadcast locally).
  Stream<GameState> get gameStream;

  /// The cards in *my* hand, updated after every play.
  Stream<List<String>> get handStream;

  /// Play a card from my hand.
  Future<void> playCard(int seat, String cardId);

  /// Resolve the current trick (called after the 4th card is played).
  void resolveTrick();

  /// Claim all remaining tricks (shortcut when on lead with unbeatable cards).
  void claimRemaining(int seat);

  /// Confirm readiness for next game.
  void confirmNextGame(String uid, int seat);

  /// Start the next game (host-only; local always auto-starts).
  void startNextGame({required String hostUid});

  /// Publish final hands so the result screen can display them.
  void publishFinalHands(String uid);

  /// Tear down streams / timers.
  void dispose();
}
