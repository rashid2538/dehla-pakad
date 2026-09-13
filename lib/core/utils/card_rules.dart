import 'dart:math';

import '../models/playing_card.dart';
import '../models/game_state.dart';

export '../models/game_state.dart'
    show VictoryType, TrickPlay, CurrentTrick, CollectedTens;

int nextSeat(int seat) => seat % 4 + 1;

String teamForSeat(int seat) => seat.isOdd ? 'teamA' : 'teamB';

int partnerSeat(int seat) => seat <= 2 ? seat + 2 : seat - 2;

bool isLegalPlay(PlayingCard card, List<PlayingCard> hand, Suit? leadSuit) {
  if (leadSuit == null) return true;
  final hasLeadSuit = hand.any((c) => c.suit == leadSuit);
  return !hasLeadSuit || card.suit == leadSuit;
}

List<PlayingCard> getLegalCards(List<PlayingCard> hand, Suit? leadSuit) {
  if (leadSuit == null) return List.of(hand);
  final suited = hand.where((c) => c.suit == leadSuit).toList();
  return suited.isEmpty ? List.of(hand) : suited;
}

/// Orders a hand for display: suits grouped, high to low within a suit, and
/// suits alternating red/black so two same-colour suits only sit side by
/// side when the suits held leave no other choice (e.g. only ♥ and ♦).
List<PlayingCard> sortHandForDisplay(List<PlayingCard> hand) {
  bool isRed(Suit s) => s == Suit.hearts || s == Suit.diamonds;
  final held = Suit.values.where((s) => hand.any((c) => c.suit == s));
  final black = held.where((s) => !isRed(s)).toList();
  final red = held.where(isRed).toList();
  final (more, fewer) = black.length >= red.length
      ? (black, red)
      : (red, black);
  final order = [
    for (var i = 0; i < more.length; i++) ...[
      more[i],
      if (i < fewer.length) fewer[i],
    ],
  ];
  return List.of(hand)..sort((a, b) {
    final bySuit = order.indexOf(a.suit).compareTo(order.indexOf(b.suit));
    return bySuit != 0 ? bySuit : b.rank.value.compareTo(a.rank.value);
  });
}

TrickPlay trickWinner(List<TrickPlay> plays, Suit leadSuit, Suit? trumpSuit) {
  assert(plays.isNotEmpty);
  final trumpPlays = trumpSuit == null
      ? <TrickPlay>[]
      : plays.where((p) => p.card.suit == trumpSuit).toList();
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

/// Returns winningTeam or null if game isn't over yet.
/// [immediate] is true when all 4 tens belong to one team (early finish).
({String? winningTeam, bool immediate}) checkVictory(
  Map<String, String?> collectedTens,
  Map<String, int> trickCounts,
) {
  final teamATens = collectedTens.values.where((t) => t == 'teamA').length;
  final teamBTens = collectedTens.values.where((t) => t == 'teamB').length;

  if (teamATens == 4) return (winningTeam: 'teamA', immediate: true);
  if (teamBTens == 4) return (winningTeam: 'teamB', immediate: true);

  final totalTricks = (trickCounts['teamA'] ?? 0) + (trickCounts['teamB'] ?? 0);
  if (totalTricks < 13) return (winningTeam: null, immediate: false);

  // All 13 tricks played — no draws
  if (teamATens != teamBTens) {
    return (
      winningTeam: teamATens > teamBTens ? 'teamA' : 'teamB',
      immediate: false,
    );
  }
  // 2-2 split: more tricks wins (13 is odd, always a winner)
  final winner = (trickCounts['teamA'] ?? 0) > (trickCounts['teamB'] ?? 0)
      ? 'teamA'
      : 'teamB';
  return (winningTeam: winner, immediate: false);
}

String teamLabel(String team) => team.replaceAll('team', 'Team ');

/// Deterministic end-of-game evaluation. Single source of truth used by the
/// game service to decide when a game must stop. Returns the winning team's
/// name plus a human-readable reason, or a null team if the game continues.
///
/// Hard gate: a game never ends before all four 10s have been won. Until then
/// the outcome is not settled no matter how the tricks fall.
///
/// Once all four 10s are in:
///  - 4-0 → that team wins
///  - 3-1 → the team holding three wins
///  - 2-2 → the first team to 7 tricks wins (majority of 13)
///  - otherwise play on to trick 13, where the trick count decides
({String? team, String? reason}) evaluateWinner({
  required Map<String, String?> collectedTens,
  required Map<String, int> trickCounts,
}) {
  final teamATens = collectedTens.values.where((t) => t == 'teamA').length;
  final teamBTens = collectedTens.values.where((t) => t == 'teamB').length;
  final tricksA = trickCounts['teamA'] ?? 0;
  final tricksB = trickCounts['teamB'] ?? 0;
  final totalTricks = tricksA + tricksB;

  ({String? team, String? reason}) win(String team, String reason) =>
      (team: team, reason: reason);

  // No early finish while a 10 is still live, even when the outcome already
  // looks settled — every 10 has to be won first.
  if (teamATens + teamBTens == 4) {
    if (teamATens == 4 || teamBTens == 4) {
      final t = teamATens == 4 ? 'teamA' : 'teamB';
      return win(t, '${teamLabel(t)} collected all four 10s.');
    }
    if (teamATens != teamBTens) {
      final t = teamATens > teamBTens ? 'teamA' : 'teamB';
      final hi = teamATens > teamBTens ? teamATens : teamBTens;
      return win(
        t,
        'All four 10s are in and ${teamLabel(t)} took $hi of '
        'them ($teamATens–$teamBTens).',
      );
    }
    // 2-2 split: whoever reaches 7 tricks has an unbeatable majority of 13.
    if (tricksA >= 7 || tricksB >= 7) {
      final t = tricksA >= 7 ? 'teamA' : 'teamB';
      final n = tricksA >= 7 ? tricksA : tricksB;
      return win(
        t,
        '10s split 2–2, so tricks decide — ${teamLabel(t)} took '
        '$n of 13, an unbeatable majority.',
      );
    }
  }

  // End of game (all 13 tricks played) — tens first, then tricks.
  if (totalTricks >= 13) {
    if (teamATens != teamBTens) {
      final t = teamATens > teamBTens ? 'teamA' : 'teamB';
      return win(
        t,
        'All 13 tricks played — ${teamLabel(t)} collected more '
        '10s ($teamATens–$teamBTens).',
      );
    }
    final t = tricksA > tricksB ? 'teamA' : 'teamB';
    return win(
      t,
      'All 13 tricks played — 10s split 2–2, so the trick '
      'majority ($tricksA–$tricksB) decides.',
    );
  }

  return (team: null, reason: null);
}

/// Cards the owner of [hand] has not seen: full deck minus every card already
/// played minus their own hand. Derived from public state only, so any client
/// can compute it without reading another player's private hand.
List<PlayingCard> unseenCards(GameState game, List<PlayingCard> hand) {
  final seen = <String>{
    ...game.trickPileA.cards,
    ...game.trickPileB.cards,
    ...?game.currentTrick?.plays.map((p) => p.card.id),
    ...hand.map((c) => c.id),
  };
  return PlayingCard.fullDeck.where((c) => !seen.contains(c.id)).toList();
}

/// True when the player *on lead* holding [hand] takes every remaining trick
/// no matter how the [unseen] cards are split among the other three seats.
///
/// A card is unbeatable when:
///  - it is a trump and no higher trump is unseen, or
///  - no trump is unseen at all (nobody can ruff) and no higher card of its
///    own suit is unseen.
///
/// [unseen] includes the partner's cards, so a partner can never overtake and
/// steal the lead either — the claimer keeps leading until the hand is out.
///
/// Sound, not complete: it never claims a position that could be lost, but it
/// misses claims that need a specific play order (e.g. drawing trumps first).
/// Requires trump to be set — before that, any off-suit play would create
/// trump and win the trick.
bool canClaimRemaining({
  required List<PlayingCard> hand,
  required List<PlayingCard> unseen,
  required Suit? trump,
}) {
  if (trump == null || hand.isEmpty || unseen.isEmpty) return false;
  final unseenTrumps = unseen.where((c) => c.suit == trump).toList();
  return hand.every((c) {
    if (c.suit == trump) {
      return !unseenTrumps.any((t) => t.rank.value > c.rank.value);
    }
    return unseenTrumps.isEmpty &&
        !unseen.any((u) => u.suit == c.suit && u.rank.value > c.rank.value);
  });
}

VictoryType determineVictoryType(String winningTeam, String? trumpTeam) =>
    winningTeam == trumpTeam ? VictoryType.court : VictoryType.poopy;

List<PlayingCard> shuffleDeck() {
  final deck = PlayingCard.fullDeck;
  final rng = Random.secure();
  for (var i = deck.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = deck[i];
    deck[i] = deck[j];
    deck[j] = tmp;
  }
  return deck;
}

Map<int, List<PlayingCard>> dealCards(
  List<PlayingCard> deck,
  int startingSeat,
) {
  final hands = {
    1: <PlayingCard>[],
    2: <PlayingCard>[],
    3: <PlayingCard>[],
    4: <PlayingCard>[],
  };
  var seat = startingSeat;
  for (final card in deck) {
    hands[seat]!.add(card);
    seat = nextSeat(seat);
  }
  return hands;
}

int determineNextGameStarter({
  required int trumpSetterSeat,
  required String trumpTeam,
  required String winningTeam,
}) {
  if (trumpTeam == winningTeam) return partnerSeat(trumpSetterSeat);
  // Opponent next clockwise from trump setter
  var seat = nextSeat(trumpSetterSeat);
  while (teamForSeat(seat) == trumpTeam) {
    seat = nextSeat(seat);
  }
  return seat;
}
