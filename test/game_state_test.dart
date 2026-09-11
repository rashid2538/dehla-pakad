import 'package:flutter_test/flutter_test.dart';

import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/playing_card.dart';

void main() {
  GameState base() => GameState(
        gameId: 'g',
        status: GameStatus.inProgress,
        roomCode: 'LOCAL',
        hostId: 'h',
        seats: const {},
        startingPlayerSeat: 1,
        currentTurnSeat: 4,
        leadSuit: Suit.spades,
        trumpSuit: Suit.hearts,
        trumpTeam: 'teamA',
        trumpSetterSeat: 2,
        winningTeam: 'teamB',
        victoryType: VictoryType.victory,
        endReason: 'the end',
        currentTrick: null,
      );

  test('omit keeps value, explicit null clears', () {
    final g = base();

    // Nothing passed → every nullable field unchanged.
    final kept = g.copyWith();
    expect(kept.currentTurnSeat, 4);
    expect(kept.leadSuit, Suit.spades);
    expect(kept.trumpSuit, Suit.hearts);
    expect(kept.trumpTeam, 'teamA');
    expect(kept.trumpSetterSeat, 2);
    expect(kept.winningTeam, 'teamB');
    expect(kept.victoryType, VictoryType.victory);
    expect(kept.endReason, 'the end');

    // Explicit null clears nullable fields (4th card of a trick, new round).
    final cleared = g.copyWith(
      currentTurnSeat: null,
      leadSuit: null,
      trumpSuit: null,
      trumpTeam: null,
      trumpSetterSeat: null,
      winningTeam: null,
      victoryType: null,
      endReason: null,
    );
    expect(cleared.currentTurnSeat, isNull);
    expect(cleared.leadSuit, isNull);
    expect(cleared.trumpSuit, isNull);
    expect(cleared.trumpTeam, isNull);
    expect(cleared.trumpSetterSeat, isNull);
    expect(cleared.winningTeam, isNull);
    expect(cleared.victoryType, isNull);
    expect(cleared.endReason, isNull);

    // Non-null overrides still work as usual.
    final updated = g.copyWith(currentTurnSeat: 2, trickNumber: 3);
    expect(updated.currentTurnSeat, 2);
    expect(updated.trickNumber, 3);
  });
}