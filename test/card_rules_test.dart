import 'package:dehla_pakad/core/models/playing_card.dart';
import 'package:dehla_pakad/core/utils/card_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sortHandForDisplay alternates suit colours when possible', () {
    String order(List<String> ids) =>
        sortHandForDisplay(ids.map(PlayingCard.fromId).toList())
            .map((c) => c.id)
            .join(' ');

    // All four suits: black/red alternate, high to low within a suit.
    expect(order(['2H', 'KD', '3S', 'AS', '9C', 'QH']), 'AS 3S QH 2H 9C KD');
    // Two blacks, one red: red sits between them.
    expect(order(['4C', '7S', '5D']), '7S 5D 4C');
    // Two reds, one black: black sits between them.
    expect(order(['4H', '7S', '5D']), '4H 7S 5D');
    // Only red suits: adjacency is unavoidable, still grouped.
    expect(order(['4D', 'JH', '9D']), 'JH 9D 4D');
  });

  test('nextSeat wraps', () {
    expect(nextSeat(1), 2);
    expect(nextSeat(4), 1);
  });

  test('teamForSeat', () {
    expect(teamForSeat(1), 'teamA');
    expect(teamForSeat(2), 'teamB');
    expect(teamForSeat(3), 'teamA');
    expect(teamForSeat(4), 'teamB');
  });

  test('partnerSeat', () {
    expect(partnerSeat(1), 3);
    expect(partnerSeat(3), 1);
    expect(partnerSeat(2), 4);
    expect(partnerSeat(4), 2);
  });

  test('follow suit enforcement', () {
    final hand = [
      PlayingCard(Suit.hearts, Rank.ace),
      PlayingCard(Suit.spades, Rank.king),
    ];
    expect(isLegalPlay(hand[0], hand, Suit.hearts), true);
    expect(isLegalPlay(hand[1], hand, Suit.hearts), false);
    expect(isLegalPlay(hand[1], hand, Suit.diamonds), true); // void
    expect(isLegalPlay(hand[0], hand, null), true); // leading
  });

  test('trick winner — trump beats lead', () {
    final plays = [
      TrickPlay(1, PlayingCard(Suit.hearts, Rank.ace)),
      TrickPlay(2, PlayingCard(Suit.hearts, Rank.king)),
      TrickPlay(3, PlayingCard(Suit.spades, Rank.two)),
      TrickPlay(4, PlayingCard(Suit.hearts, Rank.queen)),
    ];
    final winner = trickWinner(plays, Suit.hearts, Suit.spades);
    expect(winner.seat, 3); // 2 of spades (trump) beats ace of hearts
  });

  test('trick winner — highest lead suit when no trump', () {
    final plays = [
      TrickPlay(1, PlayingCard(Suit.hearts, Rank.seven)),
      TrickPlay(2, PlayingCard(Suit.hearts, Rank.ace)),
      TrickPlay(
        3,
        PlayingCard(Suit.diamonds, Rank.ace),
      ), // off-suit, irrelevant
      TrickPlay(4, PlayingCard(Suit.hearts, Rank.king)),
    ];
    final winner = trickWinner(plays, Suit.hearts, null);
    expect(winner.seat, 2);
  });

  test('checkVictory — all 4 tens immediate', () {
    final tens = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamA',
      '10C': 'teamA',
    };
    final result = checkVictory(tens, {'teamA': 5, 'teamB': 3});
    expect(result.winningTeam, 'teamA');
    expect(result.immediate, true);
  });

  test('checkVictory — 2-2 split, more tricks wins', () {
    final tens = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamB',
      '10C': 'teamB',
    };
    final result = checkVictory(tens, {'teamA': 7, 'teamB': 6});
    expect(result.winningTeam, 'teamA');
    expect(result.immediate, false);
  });

  test('evaluateWinner — all 4 tens to one team', () {
    final tens = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamA',
      '10C': 'teamA',
    };
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 5, 'teamB': 3},
      ).team,
      'teamA',
    );
    final tensB = {
      '10S': 'teamB',
      '10H': 'teamB',
      '10D': 'teamB',
      '10C': 'teamB',
    };
    expect(
      evaluateWinner(
        collectedTens: tensB,
        trickCounts: {'teamA': 2, 'teamB': 6},
      ).team,
      'teamB',
    );
  });

  test('evaluateWinner — 3-1 tens ends early', () {
    final tens = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamA',
      '10C': 'teamB',
    };
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 4, 'teamB': 4},
      ).team,
      'teamA',
    );
  });

  test('evaluateWinner — 3-0 tens plays on until the last ten falls', () {
    final tens = {'10S': 'teamA', '10H': 'teamA', '10D': 'teamA', '10C': null};
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 3, 'teamB': 4},
      ).team,
      isNull,
    );
    // Once the fourth ten is won, it ends — whichever way it goes.
    final all = {...tens, '10C': 'teamB'};
    expect(
      evaluateWinner(
        collectedTens: all,
        trickCounts: {'teamA': 3, 'teamB': 4},
      ).team,
      'teamA',
    );
  });

  test('evaluateWinner — 2-2 at 7 tricks waits for the last two tens', () {
    final tens = {'10S': 'teamA', '10H': 'teamB', '10D': null, '10C': null};
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 8, 'teamB': 2},
      ).team,
      isNull,
    );
  });

  test('evaluateWinner — reasons explain the ending', () {
    final all = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamA',
      '10C': 'teamA',
    };
    expect(
      evaluateWinner(
        collectedTens: all,
        trickCounts: {'teamA': 5, 'teamB': 3},
      ).reason,
      contains('all four 10s'),
    );
    final split = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamB',
      '10C': 'teamB',
    };
    expect(
      evaluateWinner(
        collectedTens: split,
        trickCounts: {'teamA': 7, 'teamB': 4},
      ).reason,
      contains('tricks decide'),
    );
  });

  group('canClaimRemaining', () {
    List<PlayingCard> cards(List<String> ids) =>
        ids.map(PlayingCard.fromId).toList();

    test('all trumps, none higher outstanding', () {
      expect(
        canClaimRemaining(
          hand: cards(['AS', 'KS']),
          unseen: cards(['QS', '2H', '3D', '4C']),
          trump: Suit.spades,
        ),
        isTrue,
      );
    });

    test('opponents hold no trump at all', () {
      // Low trumps still win every trick when nobody else has one.
      expect(
        canClaimRemaining(
          hand: cards(['2S', '3S']),
          unseen: cards(['AH', 'KH', 'AD', 'AC']),
          trump: Suit.spades,
        ),
        isTrue,
      );
    });

    test('a higher trump is still out', () {
      expect(
        canClaimRemaining(
          hand: cards(['KS', 'QS']),
          unseen: cards(['AS', '2H']),
          trump: Suit.spades,
        ),
        isFalse,
      );
    });

    test('top plain cards win only when no trump can ruff', () {
      expect(
        canClaimRemaining(
          hand: cards(['AH', 'KH']),
          unseen: cards(['QH', 'JH', '2D', '3C']),
          trump: Suit.spades,
        ),
        isTrue,
      );
      expect(
        canClaimRemaining(
          hand: cards(['AH', 'KH']),
          unseen: cards(['QH', '2S']),
          trump: Suit.spades,
        ),
        isFalse,
      );
    });

    test('never claims before trump is set', () {
      expect(
        canClaimRemaining(
          hand: cards(['AH', 'KH']),
          unseen: cards(['QH', 'JH']),
          trump: null,
        ),
        isFalse,
      );
    });
  });

  test('evaluateWinner — 2-2 tens, 7+ tricks wins', () {
    final tens = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamB',
      '10C': 'teamB',
    };
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 6, 'teamB': 7},
      ).team,
      'teamB',
    );
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 7, 'teamB': 6},
      ).team,
      'teamA',
    );
  });

  test('evaluateWinner — continues when not decided', () {
    // Tens not all collected and 3-x / 2-2+7 not reached yet.
    final tens = {'10S': 'teamA', '10H': 'teamA', '10D': 'teamB', '10C': null};
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 3, 'teamB': 2},
      ).team,
      isNull,
    );
    final twoTwo = {
      '10S': 'teamA',
      '10H': 'teamB',
      '10D': 'teamA',
      '10C': 'teamB',
    };
    expect(
      evaluateWinner(
        collectedTens: twoTwo,
        trickCounts: {'teamA': 6, 'teamB': 5},
      ).team,
      isNull,
    );
    final low = {'10S': null, '10H': null, '10D': null, '10C': null};
    expect(
      evaluateWinner(
        collectedTens: low,
        trickCounts: {'teamA': 6, 'teamB': 5},
      ).team,
      isNull,
    );
  });

  test('evaluateWinner — 13 tricks, 2-2 ties broken by tricks', () {
    final tens = {
      '10S': 'teamA',
      '10H': 'teamA',
      '10D': 'teamB',
      '10C': 'teamB',
    };
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 7, 'teamB': 6},
      ).team,
      'teamA',
    );
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 6, 'teamB': 7},
      ).team,
      'teamB',
    );
  });

  test('evaluateWinner — 13 tricks, tens difference decides', () {
    final tens = {'10S': 'teamA', '10H': 'teamA', '10D': 'teamB', '10C': null};
    expect(
      evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': 6, 'teamB': 7},
      ).team,
      'teamA',
    );
  });

  test('shuffleDeck returns 52 unique cards', () {
    final deck = shuffleDeck();
    expect(deck.length, 52);
    expect(deck.toSet().length, 52);
  });

  test('dealCards gives 13 per seat', () {
    final deck = shuffleDeck();
    final hands = dealCards(deck, 3);
    expect(hands.length, 4);
    for (final h in hands.values) {
      expect(h.length, 13);
    }
  });

  test('determineNextGameStarter — trump team won', () {
    expect(
      determineNextGameStarter(
        trumpSetterSeat: 2,
        trumpTeam: 'teamB',
        winningTeam: 'teamB',
      ),
      4, // partner of seat 2
    );
  });

  test('determineNextGameStarter — trump team lost', () {
    expect(
      determineNextGameStarter(
        trumpSetterSeat: 2,
        trumpTeam: 'teamB',
        winningTeam: 'teamA',
      ),
      3, // next clockwise opponent: 3 is teamA
    );
  });

  test('victoryType', () {
    expect(determineVictoryType('teamA', 'teamA'), VictoryType.court);
    expect(determineVictoryType('teamA', 'teamB'), VictoryType.poopy);
    expect(determineVictoryType('teamA', null), VictoryType.poopy);
  });
}
