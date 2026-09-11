import 'package:dehla_pakad/core/models/game_state.dart';
import 'package:dehla_pakad/core/models/player.dart';
import 'package:dehla_pakad/core/models/playing_card.dart';
import 'package:dehla_pakad/core/services/bot_engine.dart';
import 'package:flutter_test/flutter_test.dart';

GameState _makeState({
  int currentTurnSeat = 1,
  CurrentTrick? currentTrick,
  Suit? leadSuit,
  Suit? trumpSuit,
  int trickNumber = 1,
}) {
  return GameState(
    gameId: 'test',
    status: GameStatus.inProgress,
    roomCode: 'TEST',
    hostId: 'host',
    seats: {
      1: const PlayerSeat(uid: 'bot_1', displayName: 'Bot1', seat: 1, isBot: true),
      2: const PlayerSeat(uid: 'p2', displayName: 'P2', seat: 2),
      3: const PlayerSeat(uid: 'bot_3', displayName: 'Bot3', seat: 3, isBot: true),
      4: const PlayerSeat(uid: 'p4', displayName: 'P4', seat: 4),
    },
    currentTurnSeat: currentTurnSeat,
    currentTrick: currentTrick ?? const CurrentTrick(leaderSeat: 1),
    leadSuit: leadSuit,
    trumpSuit: trumpSuit,
    trickNumber: trickNumber,
  );
}

void main() {
  group('chooseBotCard', () {
    test('returns only legal card when one option', () {
      final state = _makeState(leadSuit: Suit.hearts);
      final hand = ['AH']; // only card is ace of hearts
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      expect(choice, 'AH');
    });

    test('follows suit when lead suit is set', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        currentTrick: CurrentTrick(
          leaderSeat: 4,
          plays: [TrickPlay(4, PlayingCard.fromId('5H'))],
        ),
      );
      final hand = ['3H', '7H', 'AS', 'KD'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      // Must play hearts
      final card = PlayingCard.fromId(choice);
      expect(card.suit, Suit.hearts);
    });

    test('avoids leading with 10 when possible', () {
      final state = _makeState();
      final hand = ['10H', '5S', '7D', '3C'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      expect(choice, isNot('10H'));
    });

    test('plays 10 when it is the only option', () {
      final state = _makeState(
        leadSuit: Suit.hearts,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [TrickPlay(2, PlayingCard.fromId('5H'))],
        ),
      );
      final hand = ['10H', 'AS', 'KD'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      expect(choice, '10H'); // only hearts card
    });

    test('tries to win trick containing a 10', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [
            TrickPlay(2, PlayingCard.fromId('10H')),
          ],
        ),
      );
      // Bot is seat 1 (teamA), seat 2 is teamB — opponent's 10
      final hand = ['AH', '3H', '5S'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      expect(choice, 'AH'); // play high to win the 10
    });

    test('dumps low when partner is winning and no 10', () {
      // Bot seat 1 (teamA), partner seat 3 (teamA) is currently winning
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.spades,
        currentTrick: CurrentTrick(
          leaderSeat: 3,
          plays: [
            TrickPlay(3, PlayingCard.fromId('AS')),
            TrickPlay(4, PlayingCard.fromId('5S')),
          ],
        ),
      );
      final hand = ['KS', '3S', '7D'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      expect(choice, '3S'); // dump lowest
    });

    test('trumps opponent 10 when void in lead suit', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        trumpSuit: Suit.spades,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [TrickPlay(2, PlayingCard.fromId('10H'))],
        ),
      );
      // Bot has no hearts but has trump spades
      final hand = ['2S', '7S', '5D', '3C'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      expect(choice, '2S'); // lowest trump to win
    });

    test('legal cards computed correctly when leading', () {
      final state = _makeState();
      final hand = ['AH', 'KS', '10D', '5C'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      // Should return a card from the hand
      expect(hand, contains(choice));
    });

    test('avoids leading with trump when possible', () {
      final state = _makeState(trumpSuit: Suit.spades);
      final hand = ['2S', '7S', '5D', '3H'];
      final choice = chooseBotCard(hand: hand, gameState: state, botSeat: 1);
      // Should prefer non-trump
      final card = PlayingCard.fromId(choice);
      expect(card.suit, isNot(Suit.spades));
    });

    test('leads Ace to set up safe 10 extraction', () {
      final state = _makeState();
      final hand = ['AS', '10S', '5H', '7D'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.medium,
      );
      expect(choice, 'AS');
    });
  });

  group('difficulty tiers', () {
    test('hard bot conserves trump early when no ten at stake', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        trickNumber: 2,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [TrickPlay(2, PlayingCard.fromId('3H'))],
        ),
      );
      final hand = ['3C', '5D'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.hard,
      );
      expect(choice, '5D'); // sluffs instead of wasting trump
    });

    test('easy bot always trumps in', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        trickNumber: 2,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [TrickPlay(2, PlayingCard.fromId('3H'))],
        ),
      );
      final hand = ['3C', '5D'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.easy,
      );
      expect(choice, '3C');
    });

    test('medium bot picks best suit for trump establishment', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [TrickPlay(2, PlayingCard.fromId('3H'))],
        ),
      );
      // Void in hearts, has 3 spades (inc 10) vs 1 diamond
      final hand = ['3S', '5S', '10S', '7D'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.medium,
      );
      final card = PlayingCard.fromId(choice);
      expect(card.suit, Suit.spades);
      // Should play lowest non-10 of chosen suit
      expect(choice, '3S');
    });

    test('hard bot avoids setting trump where partner is known void', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [TrickPlay(2, PlayingCard.fromId('3H'))],
        ),
      );
      final mem = BotMemory();
      // Partner seat 3 is known void in diamonds
      mem.knownVoidSuits[3]!.add(Suit.diamonds);
      // Hand: 3 spades vs 2 diamonds; without void info spades would win,
      // but diamonds are penalized because partner cannot support that trump.
      final hand = ['3S', '5S', '7D', '9D'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.hard,
        memory: mem,
      );
      final card = PlayingCard.fromId(choice);
      expect(card.suit, Suit.spades);
    });

    test('hard bot leads trump to draw when holding high trump', () {
      final state = _makeState(
        currentTurnSeat: 1,
        trumpSuit: Suit.clubs,
      );
      final hand = ['AC', '5C', '7D', '9H'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.hard,
      );
      expect(choice, '5C'); // cheapest trump to draw opponents' trumps
    });

    test('hard bot leads suit partner is void in to set up a ruff', () {
      final state = _makeState();
      final mem = BotMemory();
      // Partner seat 3 is known void in diamonds
      mem.knownVoidSuits[3]!.add(Suit.diamonds);
      final hand = ['3D', '5D', '7S', '9H'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.hard,
        memory: mem,
      );
      final card = PlayingCard.fromId(choice);
      expect(card.suit, Suit.diamonds);
      expect(choice, '3D'); // cheapest diamond
    });

    test('hard bot covers partner when a higher card may still be out', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.spades,
        trickNumber: 12,
        currentTrick: CurrentTrick(
          leaderSeat: 3,
          plays: [
            TrickPlay(3, PlayingCard.fromId('QS')), // partner winning
            TrickPlay(4, PlayingCard.fromId('5S')),
          ],
        ),
      );
      // Bot holds Ace; King is still unseen so a later opponent could beat QS
      final hand = ['AS', '3S', '7H'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.hard,
      );
      expect(choice, 'AS'); // cover partner's Queen with Ace
    });

    test('hard bot sluffs instead of trumping partner winner', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        currentTrick: CurrentTrick(
          leaderSeat: 3,
          plays: [
            TrickPlay(3, PlayingCard.fromId('AH')), // partner winning
            TrickPlay(4, PlayingCard.fromId('5H')),
          ],
        ),
      );
      final hand = ['3C', '5D', '7S'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.hard,
      );
      expect(choice, isNot('3C')); // do not trump partner
    });

    test('hard bot sluffs from shortest side suit', () {
      final state = _makeState(
        currentTurnSeat: 1,
        leadSuit: Suit.hearts,
        trumpSuit: Suit.clubs,
        currentTrick: CurrentTrick(
          leaderSeat: 2,
          plays: [TrickPlay(2, PlayingCard.fromId('3H'))],
        ),
      );
      // Void in hearts; shortest side suit is spades (1 card)
      final hand = ['2C', '5S', '7D', '9D'];
      final choice = chooseBotCard(
        hand: hand,
        gameState: state,
        botSeat: 1,
        difficulty: BotDifficulty.hard,
      );
      expect(choice, '5S'); // sluff singleton spade
    });
  });

  group('BotMemory', () {
    test('tracks void suits from off-suit plays', () {
      final mem = BotMemory();
      mem.recordPlay(
        2,
        const PlayingCard(Suit.clubs, Rank.five),
        Suit.hearts,
      );
      expect(mem.knownVoidSuits[2], contains(Suit.hearts));
    });

    test('on-suit play does not add void', () {
      final mem = BotMemory();
      mem.recordPlay(
        2,
        const PlayingCard(Suit.hearts, Rank.five),
        Suit.hearts,
      );
      expect(mem.knownVoidSuits[2], isEmpty);
    });

    test('reset clears all state', () {
      final mem = BotMemory();
      mem.recordPlay(
        3,
        const PlayingCard(Suit.spades, Rank.ace),
        Suit.hearts,
      );
      mem.reset();
      expect(mem.knownVoidSuits[3], isEmpty);
      expect(mem.playHistory, isEmpty);
    });
  });
}
