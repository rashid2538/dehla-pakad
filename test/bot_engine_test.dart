import 'dart:math';

import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/player.dart';
import 'package:dehla_pakad/core/models/playing_card.dart';
import 'package:dehla_pakad/core/services/bot_engine.dart';
import 'package:dehla_pakad/core/utils/card_rules.dart';
import 'package:flutter_test/flutter_test.dart';

GameState _makeState({
  int currentTurnSeat = 1,
  CurrentTrick? currentTrick,
  Suit? leadSuit,
  Suit? trumpSuit,
  int trickNumber = 1,
  CollectedTens collectedTens = const CollectedTens(),
  TrickPile trickPileA = const TrickPile(),
  TrickPile trickPileB = const TrickPile(),
}) {
  return GameState(
    gameId: 'test',
    status: GameStatus.inProgress,
    roomCode: 'TEST',
    hostId: 'host',
    seats: {
      1: const PlayerSeat(
        uid: 'bot_1',
        displayName: 'Bot1',
        seat: 1,
        isBot: true,
      ),
      2: const PlayerSeat(uid: 'p2', displayName: 'P2', seat: 2),
      3: const PlayerSeat(
        uid: 'bot_3',
        displayName: 'Bot3',
        seat: 3,
        isBot: true,
      ),
      4: const PlayerSeat(uid: 'p4', displayName: 'P4', seat: 4),
    },
    currentTurnSeat: currentTurnSeat,
    currentTrick: currentTrick ?? const CurrentTrick(leaderSeat: 1),
    leadSuit: leadSuit,
    trumpSuit: trumpSuit,
    trickNumber: trickNumber,
    collectedTens: collectedTens,
    trickPileA: trickPileA,
    trickPileB: trickPileB,
  );
}

BotDecision _decision({
  required List<String> hand,
  required GameState state,
  int botSeat = 1,
  BotDifficulty difficulty = BotDifficulty.hard,
  BotMemory? memory,
}) => evaluateBotDecision(
  hand: hand,
  gameState: state,
  botSeat: botSeat,
  difficulty: difficulty,
  memory: memory,
  random: Random(7),
);

BotFactorScore _factor(BotDecision decision, String cardId, String factor) =>
    decision.evaluations
        .singleWhere((evaluation) => evaluation.card.id == cardId)
        .breakdown
        .singleWhere((score) => score.factor == factor);

List<PlayingCard> _weakHandDeck(int seed) {
  final weakHand = <PlayingCard>[
    for (final suit in Suit.values) ...[
      PlayingCard(suit, Rank.two),
      PlayingCard(suit, Rank.three),
      PlayingCard(suit, Rank.four),
    ],
    const PlayingCard(Suit.spades, Rank.five),
  ];
  final remaining =
      PlayingCard.fullDeck.where((card) => !weakHand.contains(card)).toList()
        ..shuffle(Random(seed));
  final deck = <PlayingCard>[];
  for (var index = 0; index < 13; index++) {
    deck.add(weakHand[index]);
    deck.addAll(remaining.sublist(index * 3, index * 3 + 3));
  }
  return deck;
}

PlayingCard _naiveCard({
  required List<PlayingCard> hand,
  required GameState game,
  required int seat,
}) {
  final plays = game.currentTrick!.plays;
  final leadSuit = plays.isEmpty
      ? null
      : game.leadSuit ?? plays.first.card.suit;
  final legal = getLegalCards(hand, leadSuit);
  if (plays.isEmpty) {
    legal.sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return legal.first;
  }

  bool wins(PlayingCard card) {
    final trump = game.trumpSuit ?? (card.suit != leadSuit ? card.suit : null);
    return trickWinner(
          [...plays, TrickPlay(seat, card)],
          leadSuit!,
          trump,
        ).seat ==
        seat;
  }

  final winners = legal.where(wins).toList()
    ..sort((a, b) => a.rank.value.compareTo(b.rank.value));
  if (winners.isNotEmpty) return winners.first;
  legal.sort((a, b) => a.rank.value.compareTo(b.rank.value));
  return legal.first;
}

int _simulateWeakHandTeamTens({required int seed, required bool naiveTarget}) {
  final hands = dealCards(_weakHandDeck(seed), 1);
  final memory = BotMemory();
  var game = _makeState(
    currentTurnSeat: 1,
    currentTrick: const CurrentTrick(leaderSeat: 1),
  );

  for (var turn = 0; turn < 52; turn++) {
    final seat = game.currentTurnSeat!;
    final hand = hands[seat]!;
    final card = seat == 1 && naiveTarget
        ? _naiveCard(hand: hand, game: game, seat: seat)
        : evaluateBotDecision(
            hand: hand.map((held) => held.id).toList(),
            gameState: game,
            botSeat: seat,
            // Medium: tests the scoring model, not Hard's look-ahead (slow).
            difficulty: BotDifficulty.medium,
            memory: memory,
            random: Random(seed * 100 + turn),
          ).card;
    final previousPlays = game.currentTrick!.plays;
    final leadSuit = game.leadSuit ?? card.suit;
    final establishesTrump =
        game.trumpSuit == null &&
        previousPlays.isNotEmpty &&
        card.suit != leadSuit;
    final trumpSuit = establishesTrump ? card.suit : game.trumpSuit;
    final trick = CurrentTrick(
      leaderSeat: game.currentTrick!.leaderSeat,
      plays: [...previousPlays, TrickPlay(seat, card)],
    );
    hand.remove(card);

    if (trick.plays.length < 4) {
      game = game.copyWith(
        currentTurnSeat: GameState.nextSeat(seat),
        leadSuit: leadSuit,
        trumpSuit: trumpSuit,
        trumpTeam: establishesTrump
            ? GameState.teamForSeat(seat)
            : game.trumpTeam,
        trumpSetterSeat: establishesTrump ? seat : game.trumpSetterSeat,
        currentTrick: trick,
      );
      continue;
    }

    final winner = trickWinner(trick.plays, leadSuit, trumpSuit);
    final winnerTeam = GameState.teamForSeat(winner.seat);
    final tens = Map<String, String?>.from(game.collectedTens.tens);
    for (final play in trick.plays.where((play) => play.card.isTen)) {
      tens[play.card.id] = winnerTeam;
    }
    for (final play in trick.plays) {
      memory.recordPlay(play.seat, play.card, leadSuit);
    }
    final wonByA = winnerTeam == 'teamA';
    final pileA = wonByA
        ? TrickPile(
            trickCount: game.trickPileA.trickCount + 1,
            cards: [
              ...game.trickPileA.cards,
              ...trick.plays.map((play) => play.card.id),
            ],
          )
        : game.trickPileA;
    final pileB = wonByA
        ? game.trickPileB
        : TrickPile(
            trickCount: game.trickPileB.trickCount + 1,
            cards: [
              ...game.trickPileB.cards,
              ...trick.plays.map((play) => play.card.id),
            ],
          );
    game = game.copyWith(
      currentTurnSeat: winner.seat,
      leadSuit: null,
      trumpSuit: trumpSuit,
      trumpTeam: establishesTrump
          ? GameState.teamForSeat(seat)
          : game.trumpTeam,
      trumpSetterSeat: establishesTrump ? seat : game.trumpSetterSeat,
      trickNumber: game.trickNumber + 1,
      currentTrick: CurrentTrick(leaderSeat: winner.seat),
      collectedTens: CollectedTens(tens: tens),
      trickPileA: pileA,
      trickPileB: pileB,
    );
  }

  return game.collectedTens.tensForTeam('teamA');
}

void main() {
  group('chooseBotCard compatibility', () {
    test('returns the only legal card without scoring alternatives', () {
      final state = _makeState(leadSuit: Suit.hearts);
      final choice = chooseBotCard(
        hand: ['AH'],
        gameState: state,
        botSeat: 1,
        random: Random(1),
      );

      expect(choice, 'AH');
    });

    test('never violates the mandatory follow-suit rule', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        currentTrick: CurrentTrick(
          leaderSeat: 4,
          plays: [TrickPlay(4, PlayingCard.fromId('5H'))],
        ),
      );
      final choice = chooseBotCard(
        hand: ['3H', '7H', 'AS', 'KD'],
        gameState: state,
        botSeat: 1,
        random: Random(1),
      );

      expect(PlayingCard.fromId(choice).suit, Suit.hearts);
    });

    test('keeps the existing string-returning selector interface', () {
      final state = _makeState();
      final hand = ['10H', '5S', '7D', '3C'];

      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        random: Random(1),
      );

      expect(hand, contains(choice));
      expect(choice, isNot('10H'));
    });
  });

  group('unified card evaluation', () {
    test(
      'disposes a ten safely when partner wins and no safe discard exists',
      () {
        final state = _makeState(
          leadSuit: Suit.hearts,
          trumpSuit: Suit.clubs,
          currentTrick: CurrentTrick(
            leaderSeat: 3,
            plays: [
              TrickPlay(3, PlayingCard.fromId('AH')),
              TrickPlay(4, PlayingCard.fromId('5H')),
            ],
          ),
        );
        final decision = _decision(hand: ['10S', '3C'], state: state);

        expect(decision.card.id, '10S');
        expect(
          _factor(decision, '10S', 'ten_management').contribution,
          greaterThan(0),
        );
      },
    );

    test('banks a ten on a partner trick nobody is likely to overtake', () {
      final state = _makeState(
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        currentTrick: CurrentTrick(
          leaderSeat: 3,
          plays: [
            TrickPlay(3, PlayingCard.fromId('AH')),
            TrickPlay(4, PlayingCard.fromId('5H')),
          ],
        ),
      );
      final decision = _decision(hand: ['10S', '3D', '7C'], state: state);

      expect(decision.card.id, '10S');
      expect(
        _factor(decision, '10S', 'ten_management').contribution,
        greaterThan(0),
      );
    });

    test('retains a ten when the partner trick can be trumped', () {
      final state = _makeState(
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        currentTrick: CurrentTrick(
          leaderSeat: 3,
          plays: [
            TrickPlay(3, PlayingCard.fromId('AH')),
            TrickPlay(4, PlayingCard.fromId('5H')),
          ],
        ),
      );
      final memory = BotMemory()
        ..recordPlay(2, PlayingCard.fromId('2C'), Suit.hearts);
      final decision = _decision(
        hand: ['10S', '3D', '7C'],
        state: state,
        memory: memory,
      );

      expect(decision.card.id, '3D');
      expect(
        _factor(decision, '10S', 'ten_management').contribution,
        lessThan(0),
      );
    });

    test('captures an opponent trick with the cheapest winning ten', () {
      final state = _makeState(
        leadSuit: Suit.hearts,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [
            TrickPlay(2, PlayingCard.fromId('9H')),
            TrickPlay(3, PlayingCard.fromId('3H')),
            TrickPlay(4, PlayingCard.fromId('5H')),
          ],
        ),
      );
      final decision = _decision(hand: ['10H', 'AH'], state: state);

      expect(decision.card.id, '10H');
      expect(
        _factor(decision, '10H', 'ten_management').contribution,
        greaterThan(0),
      );
    });

    test(
      'does not feed an unwinnable ten to opponents when a discard exists',
      () {
        final state = _makeState(
          leadSuit: Suit.spades,
          trumpSuit: Suit.clubs,
          currentTrick: CurrentTrick(
            leaderSeat: 2,
            plays: [
              TrickPlay(2, PlayingCard.fromId('AS')),
              TrickPlay(3, PlayingCard.fromId('3S')),
              TrickPlay(4, PlayingCard.fromId('4S')),
            ],
          ),
        );
        final decision = _decision(hand: ['10D', '2H'], state: state);

        expect(decision.card.id, '2H');
        expect(
          _factor(decision, '10D', 'ten_management').contribution,
          lessThan(0),
        );
      },
    );

    test('conserves a strong trump on an early empty trick', () {
      final state = _makeState(
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        trickNumber: 2,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [
            TrickPlay(2, PlayingCard.fromId('3H')),
            TrickPlay(3, PlayingCard.fromId('4H')),
            TrickPlay(4, PlayingCard.fromId('5H')),
          ],
        ),
      );
      final decision = _decision(hand: ['AC', '2D'], state: state);

      expect(decision.card.id, '2D');
      expect(
        _factor(decision, 'AC', 'trump_preservation').contribution,
        lessThan(0),
      );
    });

    test(
      'spends the weakest sufficient trump to capture a ten-bearing trick',
      () {
        final state = _makeState(
          leadSuit: Suit.hearts,
          trumpSuit: Suit.clubs,
          currentTrick: CurrentTrick(
            leaderSeat: 2,
            plays: [
              TrickPlay(2, PlayingCard.fromId('10H')),
              TrickPlay(3, PlayingCard.fromId('3H')),
              TrickPlay(4, PlayingCard.fromId('5H')),
            ],
          ),
        );
        final decision = _decision(hand: ['2C', '7C', '4D'], state: state);

        expect(decision.card.id, '2C');
        expect(
          _factor(decision, '2C', 'trump_preservation').contribution,
          greaterThan(0),
        );
      },
    );

    test('releases a strong trump in the endgame when it wins', () {
      final state = _makeState(
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        trickNumber: 12,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [
            TrickPlay(2, PlayingCard.fromId('5H')),
            TrickPlay(3, PlayingCard.fromId('3H')),
            TrickPlay(4, PlayingCard.fromId('4H')),
          ],
        ),
      );
      final decision = _decision(hand: ['AC', '2D'], state: state);

      expect(decision.card.id, 'AC');
      expect(
        _factor(decision, 'AC', 'trump_preservation').contribution,
        greaterThan(-1.4),
      );
    });

    test('discards the lowest-retention non-ten when no card can win', () {
      final state = _makeState(
        leadSuit: Suit.spades,
        trumpSuit: Suit.clubs,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [
            TrickPlay(2, PlayingCard.fromId('AS')),
            TrickPlay(3, PlayingCard.fromId('3S')),
            TrickPlay(4, PlayingCard.fromId('4S')),
          ],
        ),
      );
      final decision = _decision(hand: ['10D', '2H', 'KD'], state: state);

      expect(decision.card.id, '2H');
    });

    test('uses an ace lead to prepare a protected ten', () {
      final decision = _decision(
        hand: ['AS', '10S', '5H', '7D'],
        state: _makeState(),
      );

      expect(decision.card.id, 'AS');
      expect(
        _factor(decision, 'AS', 'future_value').contribution,
        greaterThan(0),
      );
      expect(
        _factor(decision, '10S', 'future_value').contribution,
        lessThan(0),
      );
    });

    test(
      'scores overtake risk for a winning card with opponents remaining',
      () {
        final decision = _decision(hand: ['QS', '2D'], state: _makeState());

        expect(
          _factor(decision, 'QS', 'overtake_risk').contribution,
          lessThan(0),
        );
      },
    );

    test(
      'only adds partner-cover pressure when a lower-risk overtake exists',
      () {
        final state = _makeState(
          leadSuit: Suit.spades,
          currentTrick: CurrentTrick(
            leaderSeat: 3,
            plays: [
              TrickPlay(3, PlayingCard.fromId('9S')),
              TrickPlay(4, PlayingCard.fromId('5S')),
            ],
          ),
        );
        final decision = _decision(hand: ['AS', '3S'], state: state);

        expect(
          _factor(decision, 'AS', 'team_position').contribution,
          greaterThan(0),
        );
        expect(_factor(decision, '3S', 'team_position').contribution, 0);
      },
    );

    test(
      'uses the trump-establishment pre-filter before unified card scoring',
      () {
        final state = _makeState(
          currentTurnSeat: 3,
          leadSuit: Suit.hearts,
          currentTrick: CurrentTrick(
            leaderSeat: 1,
            plays: [
              TrickPlay(1, PlayingCard.fromId('3H')),
              TrickPlay(2, PlayingCard.fromId('5H')),
            ],
          ),
        );
        final decision = _decision(
          botSeat: 3,
          hand: ['3S', '5S', '10S', '7D'],
          state: state,
        );

        expect(decision.card.suit, Suit.spades);
        // Setting trump with the ten wins the trick and banks the ten at once.
        expect(decision.card.id, '10S');
      },
    );

    test('returns trace text from the selected factor breakdown', () {
      final decision = _decision(
        hand: ['AS', '10S', '5H', '7D'],
        state: _makeState(),
      );

      expect(decision.trace, contains('Selected: AS'));
      expect(decision.trace, contains('future_value'));
      expect(decision.trace, contains('Total score:'));
    });
  });

  group('weak-hand simulation', () {
    test(
      'team-first scoring beats a naive always-win policy across fixed deals',
      () {
        var unifiedTens = 0;
        var naiveTens = 0;
        for (var seed = 1; seed <= 24; seed++) {
          unifiedTens += _simulateWeakHandTeamTens(
            seed: seed,
            naiveTarget: false,
          );
          naiveTens += _simulateWeakHandTeamTens(seed: seed, naiveTarget: true);
        }

        expect(unifiedTens, greaterThan(naiveTens));
      },
    );
  });

  group('BotMemory', () {
    test('tracks void suits from off-suit plays', () {
      final memory = BotMemory();
      memory.recordPlay(
        2,
        const PlayingCard(Suit.clubs, Rank.five),
        Suit.hearts,
      );

      expect(memory.knownVoidSuits[2], contains(Suit.hearts));
    });

    test('on-suit play does not add void', () {
      final memory = BotMemory();
      memory.recordPlay(
        2,
        const PlayingCard(Suit.hearts, Rank.five),
        Suit.hearts,
      );

      expect(memory.knownVoidSuits[2], isEmpty);
    });

    test('reset clears all state', () {
      final memory = BotMemory();
      memory.recordPlay(
        3,
        const PlayingCard(Suit.spades, Rank.ace),
        Suit.hearts,
      );
      memory.reset();

      expect(memory.knownVoidSuits[3], isEmpty);
      expect(memory.playHistory, isEmpty);
    });
  });
}
