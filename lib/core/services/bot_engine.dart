import '../models/game_state.dart';
import '../models/playing_card.dart';
import '../utils/card_rules.dart';

String chooseBotCard({
  required List<String> hand,
  required GameState gameState,
  required int botSeat,
}) {
  final cards = hand.map(PlayingCard.fromId).toList();
  final trick = gameState.currentTrick;
  final isLeading = trick == null || trick.plays.isEmpty;
  final leadSuit = isLeading ? null : gameState.leadSuit;
  final legal = getLegalCards(cards, leadSuit);

  if (legal.length == 1) return legal.first.id;

  final botTeam = GameState.teamForSeat(botSeat);
  final trumpSuit = gameState.trumpSuit;

  if (isLeading) {
    return _chooseLead(legal, trumpSuit).id;
  }
  return _chooseFollow(legal, trick, leadSuit!, trumpSuit, botTeam).id;
}

PlayingCard _chooseLead(List<PlayingCard> legal, Suit? trumpSuit) {
  // Avoid leading with 10s
  final safe = legal.where((c) => !c.isTen).toList();
  final pool = safe.isNotEmpty ? safe : legal;

  // Avoid leading with trump
  final nonTrump = pool.where((c) => c.suit != trumpSuit).toList();
  final candidates = nonTrump.isNotEmpty ? nonTrump : pool;

  // Lead high card from longest suit
  final suitCounts = <Suit, int>{};
  for (final c in candidates) {
    suitCounts[c.suit] = (suitCounts[c.suit] ?? 0) + 1;
  }
  final bestSuit =
      suitCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  final suitCards = candidates.where((c) => c.suit == bestSuit).toList()
    ..sort((a, b) => b.rank.value.compareTo(a.rank.value));

  return suitCards.first;
}

PlayingCard _chooseFollow(
  List<PlayingCard> legal,
  CurrentTrick trick,
  Suit leadSuit,
  Suit? trumpSuit,
  String botTeam,
) {
  final hasTen = trick.plays.any((p) => p.card.isTen);
  final winner = trickWinner(trick.plays, leadSuit, trumpSuit);
  final partnerWinning = GameState.teamForSeat(winner.seat) == botTeam;
  final followingSuit = legal.every((c) => c.suit == leadSuit);

  if (followingSuit) {
    return _followSuit(legal, hasTen, partnerWinning, winner);
  }
  return _playVoid(legal, hasTen, partnerWinning, winner, trumpSuit);
}

PlayingCard _followSuit(
  List<PlayingCard> legal,
  bool hasTen,
  bool partnerWinning,
  TrickPlay winner,
) {
  final sorted = List.of(legal)
    ..sort((a, b) => b.rank.value.compareTo(a.rank.value));

  if (hasTen && !partnerWinning) return sorted.first;

  if (partnerWinning) {
    final safe = sorted.where((c) => !c.isTen).toList();
    return safe.isNotEmpty ? safe.last : sorted.last;
  }

  // Try to win with lowest winning card
  final canWin =
      sorted.where((c) => c.rank.value > winner.card.rank.value).toList();
  if (canWin.isNotEmpty) return canWin.last;

  // Can't win — dump lowest non-10
  final safe = sorted.where((c) => !c.isTen).toList();
  return safe.isNotEmpty ? safe.last : sorted.last;
}

PlayingCard _playVoid(
  List<PlayingCard> legal,
  bool hasTen,
  bool partnerWinning,
  TrickPlay winner,
  Suit? trumpSuit,
) {
  final trumpCards = trumpSuit != null
      ? legal.where((c) => c.suit == trumpSuit).toList()
      : <PlayingCard>[];
  final nonTrump = legal.where((c) => c.suit != trumpSuit).toList();

  // Trump the ten
  if (hasTen && !partnerWinning && trumpCards.isNotEmpty) {
    final sortedTrump = List.of(trumpCards)
      ..sort((a, b) => a.rank.value.compareTo(b.rank.value));
    if (winner.card.suit == trumpSuit) {
      final canBeat = sortedTrump
          .where((c) => c.rank.value > winner.card.rank.value)
          .toList();
      if (canBeat.isNotEmpty) return canBeat.first;
    } else {
      return sortedTrump.first;
    }
  }

  // Partner winning or nothing valuable — discard lowest non-trump non-10
  final discardPool = partnerWinning || !hasTen ? nonTrump : legal;
  final safe = discardPool.where((c) => !c.isTen).toList();
  if (safe.isNotEmpty) {
    safe.sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return safe.first;
  }
  if (nonTrump.isNotEmpty) {
    nonTrump.sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return nonTrump.first;
  }
  // Only trump left
  trumpCards.sort((a, b) => a.rank.value.compareTo(b.rank.value));
  return trumpCards.first;
}
