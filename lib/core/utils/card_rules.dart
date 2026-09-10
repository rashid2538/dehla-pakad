import 'dart:math';

import '../models/playing_card.dart';
import '../models/game_state.dart';

export '../models/game_state.dart' show VictoryType, TrickPlay, CurrentTrick, CollectedTens;

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

TrickPlay trickWinner(List<TrickPlay> plays, Suit leadSuit, Suit? trumpSuit) {
  assert(plays.isNotEmpty);
  final trumpPlays =
      trumpSuit == null ? <TrickPlay>[] : plays.where((p) => p.card.suit == trumpSuit).toList();
  if (trumpPlays.isNotEmpty) {
    return trumpPlays.reduce((a, b) => a.card.rank.value >= b.card.rank.value ? a : b);
  }
  final leadPlays = plays.where((p) => p.card.suit == leadSuit).toList();
  return leadPlays.reduce((a, b) => a.card.rank.value >= b.card.rank.value ? a : b);
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
    return (winningTeam: teamATens > teamBTens ? 'teamA' : 'teamB', immediate: false);
  }
  // 2-2 split: more tricks wins (13 is odd, always a winner)
  final winner = (trickCounts['teamA'] ?? 0) > (trickCounts['teamB'] ?? 0) ? 'teamA' : 'teamB';
  return (winningTeam: winner, immediate: false);
}

/// Deterministic end-of-game evaluation. Single source of truth used by the
/// game service to decide when a game must stop. Returns the winning team's
/// name, or null if the game should continue.
///
/// Covers every no-draw termination rule:
///  - All 4 tens to one team
///  - 3+ tens vs fewer tens (3-1 or 3-0 split)
///  - 2-2 tens with a team at 7+ tricks
///  - All 13 tricks played (tens, then tricks, as tie-breakers)
String? evaluateWinner({
  required Map<String, String?> collectedTens,
  required Map<String, int> trickCounts,
}) {
  final teamATens = collectedTens.values.where((t) => t == 'teamA').length;
  final teamBTens = collectedTens.values.where((t) => t == 'teamB').length;
  final tricksA = trickCounts['teamA'] ?? 0;
  final tricksB = trickCounts['teamB'] ?? 0;
  final totalTricks = tricksA + tricksB;

  // All four tens to one team — immediate win.
  if (teamATens == 4) return 'teamA';
  if (teamBTens == 4) return 'teamB';

  // Three tens (or more than the opponent has collected) — the holder wins.
  if (teamATens >= 3 && teamATens > teamBTens) return 'teamA';
  if (teamBTens >= 3 && teamBTens > teamATens) return 'teamB';

  // Two-all split: whoever reaches 7+ tricks wins immediately.
  if (teamATens == 2 && teamBTens == 2) {
    if (tricksA >= 7) return 'teamA';
    if (tricksB >= 7) return 'teamB';
  }

  // End of game (all 13 tricks played) — tens first, then tricks.
  if (totalTricks >= 13) {
    if (teamATens != teamBTens) return teamATens > teamBTens ? 'teamA' : 'teamB';
    return tricksA > tricksB ? 'teamA' : 'teamB';
  }

  return null;
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

Map<int, List<PlayingCard>> dealCards(List<PlayingCard> deck, int startingSeat) {
  final hands = {1: <PlayingCard>[], 2: <PlayingCard>[], 3: <PlayingCard>[], 4: <PlayingCard>[]};
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
