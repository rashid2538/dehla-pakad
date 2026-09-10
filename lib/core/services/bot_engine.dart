import 'dart:math';

import '../models/game_state.dart';
import '../models/player.dart';
import '../models/playing_card.dart';
import '../utils/card_rules.dart';

/// Tracks what the bot can infer from public play history.
/// Built incrementally by BotController as tricks are observed.
class BotMemory {
  /// Suits each seat is known to be void in (they failed to follow).
  final Map<int, Set<Suit>> knownVoidSuits = {1: {}, 2: {}, 3: {}, 4: {}};

  /// Every card played so far, with seat attribution.
  final List<({int seat, PlayingCard card})> playHistory = [];

  void recordPlay(int seat, PlayingCard card, Suit? leadSuit) {
    playHistory.add((seat: seat, card: card));
    if (leadSuit != null && card.suit != leadSuit) {
      knownVoidSuits[seat]!.add(leadSuit);
    }
  }

  void reset() {
    for (final s in knownVoidSuits.values) {
      s.clear();
    }
    playHistory.clear();
  }

  Set<String> get allPlayedCardIds =>
      playHistory.map((p) => p.card.id).toSet();
}

String chooseBotCard({
  required List<String> hand,
  required GameState gameState,
  required int botSeat,
  BotDifficulty difficulty = BotDifficulty.medium,
  BotMemory? memory,
}) {
  final cards = hand.map(PlayingCard.fromId).toList();
  final trick = gameState.currentTrick;
  final isLeading = trick == null || trick.plays.isEmpty;
  final leadSuit = isLeading
      ? null
      : (gameState.leadSuit ?? trick.plays.first.card.suit);
  final legal = getLegalCards(cards, leadSuit);

  if (legal.length == 1) return legal.first.id;

  final botTeam = GameState.teamForSeat(botSeat);
  final trumpSuit = gameState.trumpSuit;
  final ctx = _BotContext(
    botSeat: botSeat,
    botTeam: botTeam,
    trumpSuit: trumpSuit,
    trumpEstablished: trumpSuit != null,
    trickNumber: gameState.trickNumber,
    trick: trick,
    leadSuit: leadSuit,
    collectedTens: gameState.collectedTens,
    trickPileA: gameState.trickPileA,
    trickPileB: gameState.trickPileB,
    memory: memory ?? BotMemory(),
    allCards: cards,
  );

  if (isLeading) {
    return _chooseLead(legal, ctx, difficulty).id;
  }
  final followingSuit = legal.every((c) => c.suit == leadSuit);
  if (followingSuit) {
    return _followSuit(legal, ctx, difficulty).id;
  }
  return _playVoid(legal, ctx, difficulty).id;
}

class _BotContext {
  final int botSeat;
  final String botTeam;
  final Suit? trumpSuit;
  final bool trumpEstablished;
  final int trickNumber;
  final CurrentTrick? trick;
  final Suit? leadSuit;
  final CollectedTens collectedTens;
  final TrickPile trickPileA;
  final TrickPile trickPileB;
  final BotMemory memory;
  final List<PlayingCard> allCards;

  _BotContext({
    required this.botSeat,
    required this.botTeam,
    required this.trumpSuit,
    required this.trumpEstablished,
    required this.trickNumber,
    required this.trick,
    required this.leadSuit,
    required this.collectedTens,
    required this.trickPileA,
    required this.trickPileB,
    required this.memory,
    required this.allCards,
  });

  bool get isPartnerWinning {
    if (trick == null || trick!.plays.isEmpty) return false;
    final w = trickWinner(trick!.plays, leadSuit!, trumpSuit);
    return GameState.teamForSeat(w.seat) == botTeam;
  }

  bool get trickHasTen => trick?.plays.any((p) => p.card.isTen) ?? false;

  int get tricksRemaining => 14 - trickNumber;

  int get partnerSeat => GameState.partnerSeat(botSeat);

  Set<String> get cardsAccountedFor {
    final s = <String>{};
    for (final c in allCards) {
      s.add(c.id);
    }
    s.addAll(trickPileA.cards);
    s.addAll(trickPileB.cards);
    if (trick != null) {
      for (final p in trick!.plays) {
        s.add(p.card.id);
      }
    }
    return s;
  }

  Set<String> get cardsUnseen {
    final all = PlayingCard.fullDeck.map((c) => c.id).toSet();
    return all.difference(cardsAccountedFor);
  }

  bool isOpponentSeat(int seat) => GameState.teamForSeat(seat) != botTeam;

  bool opponentKnownVoidIn(Suit suit) {
    for (final seat in [1, 2, 3, 4]) {
      if (seat == botSeat || seat == partnerSeat) continue;
      if (memory.knownVoidSuits[seat]!.contains(suit)) return true;
    }
    return false;
  }
}

// ── Leading (§6) ──

PlayingCard _chooseLead(
    List<PlayingCard> legal, _BotContext ctx, BotDifficulty diff) {
  if (diff == BotDifficulty.easy) {
    return _easyLead(legal, ctx);
  }
  return _smartLead(legal, ctx, diff);
}

PlayingCard _easyLead(List<PlayingCard> legal, _BotContext ctx) {
  final safe = legal.where((c) => !c.isTen).toList();
  final pool = safe.isNotEmpty ? safe : legal;
  return pool[Random().nextInt(pool.length)];
}

PlayingCard _smartLead(
    List<PlayingCard> legal, _BotContext ctx, BotDifficulty diff) {
  // §6.1/6.2: Ace-then-Ten plan — if we hold an Ace, lead it to clear the
  // path for a safe 10 lead next trick. If the Ace of a suit is already
  // played (in piles or history), the 10 of that suit may be safe to lead.
  final candidateTens = legal.where((c) => c.isTen).toList();
  final safeTens = candidateTens.where((c) => _isLeadingTenSafe(c, ctx, legal)).toList();

  // Prefer leading an Ace whose suit has a 10 we hold (sets up next trick)
  final acesSettingUpTen = legal.where((c) =>
      c.rank == Rank.ace &&
      ctx.allCards.any((h) => h.isTen && h.suit == c.suit)).toList();
  if (acesSettingUpTen.isNotEmpty) {
    return acesSettingUpTen.first;
  }

  // Safe tens (Ace already spent, no opponent known-void that could trump)
  if (safeTens.isNotEmpty) {
    return safeTens.first;
  }

  // Avoid leading 10s and trump
  final safe = legal.where((c) => !c.isTen).toList();
  final pool = safe.isNotEmpty ? safe : legal;
  final nonTrump = pool.where((c) => c.suit != ctx.trumpSuit).toList();
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

/// §6.2: Is it safe to lead this 10?
bool _isLeadingTenSafe(PlayingCard ten, _BotContext ctx, List<PlayingCard> legal) {
  // The Ace of this suit must already be accounted for (played or we hold it)
  final aceInHand = ctx.allCards.any((c) => c.suit == ten.suit && c.rank == Rank.ace);
  final aceInPiles = ctx.cardsAccountedFor.contains('A${ten.suit.letter}');
  if (!aceInHand && !aceInPiles) return false;
  // If trump is set and an opponent is known-void in this suit, they can trump it
  if (ctx.trumpEstablished && ten.suit != ctx.trumpSuit) {
    if (ctx.opponentKnownVoidIn(ten.suit)) return false;
  }
  return true;
}

// ── Following suit (§7) ──

PlayingCard _followSuit(
    List<PlayingCard> legal, _BotContext ctx, BotDifficulty diff) {
  final sorted = List.of(legal)
    ..sort((a, b) => b.rank.value.compareTo(a.rank.value));
  final winner = trickWinner(ctx.trick!.plays, ctx.leadSuit!, ctx.trumpSuit);

  if (ctx.isPartnerWinning) {
    // Partner is winning — play low, but protect a ten if an opponent plays after us
    if (ctx.trickHasTen && _laterOpponentCanPlay(ctx)) {
      // Try to overtake with cheapest winner to secure the ten
      final canWin = sorted
          .where((c) => _beatsCurrentWinner(c, winner, ctx))
          .toList();
      if (canWin.isNotEmpty) return canWin.last;
    }
    // Duck — lowest non-10
    final safe = sorted.where((c) => !c.isTen).toList();
    return safe.isNotEmpty ? safe.last : sorted.last;
  }

  // Opponent winning — try to win
  if (ctx.trickHasTen || diff != BotDifficulty.easy) {
    final canWin = sorted
        .where((c) => _beatsCurrentWinner(c, winner, ctx))
        .toList();
    if (canWin.isNotEmpty) return canWin.last; // cheapest winner
  }

  // Can't win — dump lowest non-10
  final safe = sorted.where((c) => !c.isTen).toList();
  return safe.isNotEmpty ? safe.last : sorted.last;
}

bool _beatsCurrentWinner(PlayingCard card, TrickPlay winner, _BotContext ctx) {
  // Same suit comparison only (we're following suit, not trumping)
  if (card.suit != winner.card.suit) return false;
  return card.rank.value > winner.card.rank.value;
}

bool _laterOpponentCanPlay(_BotContext ctx) {
  if (ctx.trick == null) return false;
  final played = ctx.trick!.plays.length;
  // Walk remaining seats in play order to see if an opponent is still to act
  var seat = ctx.botSeat;
  for (var i = played; i < 4; i++) {
    seat = GameState.nextSeat(seat);
    if (ctx.isOpponentSeat(seat)) return true;
  }
  return false;
}

// ── Void play (§8) ──

PlayingCard _playVoid(
    List<PlayingCard> legal, _BotContext ctx, BotDifficulty diff) {
  final trumpCards = ctx.trumpSuit != null
      ? legal.where((c) => c.suit == ctx.trumpSuit).toList()
      : <PlayingCard>[];
  final nonTrump = legal.where((c) => c.suit != ctx.trumpSuit).toList();

  // §8.1: Trump not yet established — this play sets it
  if (!ctx.trumpEstablished) {
    return _chooseTrumpEstablishing(legal, ctx, diff);
  }

  // §8.2: Should we trump in?
  if (trumpCards.isNotEmpty && !ctx.isPartnerWinning) {
    final shouldTrump = _shouldTrumpIn(trumpCards, ctx, diff);
    if (shouldTrump) {
      return _cheapestTrumpThatWins(trumpCards, ctx);
    }
  }

  // §8.3: Sluff
  return _chooseSluff(nonTrump.isNotEmpty ? nonTrump : legal, ctx);
}

/// §8.1: Choose which suit to establish as trump.
PlayingCard _chooseTrumpEstablishing(
    List<PlayingCard> legal, _BotContext ctx, BotDifficulty diff) {
  if (diff == BotDifficulty.easy) {
    // Random off-suit, avoiding 10s
    final safe = legal.where((c) => !c.isTen).toList();
    final pool = safe.isNotEmpty ? safe : legal;
    return pool[Random().nextInt(pool.length)];
  }

  // Score each candidate suit for trump quality
  final suitScores = <Suit, double>{};
  for (final card in legal) {
    if (suitScores.containsKey(card.suit)) continue;
    suitScores[card.suit] = _evaluateTrumpSuitQuality(card.suit, ctx);
  }

  final bestSuit = suitScores.entries
      .reduce((a, b) => a.value >= b.value ? a : b)
      .key;

  // Play lowest card of chosen suit — save high trump for winning tricks
  final suitCards = legal.where((c) => c.suit == bestSuit).toList()
    ..sort((a, b) => a.rank.value.compareTo(b.rank.value));
  // Avoid spending a 10 to set trump if possible
  final nonTen = suitCards.where((c) => !c.isTen).toList();
  return nonTen.isNotEmpty ? nonTen.first : suitCards.first;
}

double _evaluateTrumpSuitQuality(Suit suit, _BotContext ctx) {
  final cardsInSuit = ctx.allCards.where((c) => c.suit == suit).toList();
  var score = 0.0;
  // Length is king — more trump = more control
  score += cardsInSuit.length * 3.0;
  // High cards bonus
  for (final c in cardsInSuit) {
    if (c.rank == Rank.ace) score += 5.0;
    if (c.rank == Rank.king) score += 3.0;
    if (c.rank == Rank.queen) score += 2.0;
    if (c.rank == Rank.jack) score += 1.0;
  }
  // Holding the 10 of this suit is a big bonus — it becomes nearly unbeatable as trump
  if (cardsInSuit.any((c) => c.isTen)) score += 6.0;
  return score;
}

/// §8.2: Decide whether to spend a trump card on this trick.
bool _shouldTrumpIn(
    List<PlayingCard> trumpCards, _BotContext ctx, BotDifficulty diff) {
  // Always trump to capture an opponent's ten
  if (ctx.trickHasTen) return true;

  if (diff == BotDifficulty.easy) return true; // Easy always trumps

  // Hard: conserve trump for ten-bearing tricks in mid/late game
  if (diff == BotDifficulty.hard && !ctx.trickHasTen) {
    // ponytail: simple trump conservation — save trump when >6 tricks remain
    // and no tens at stake. Upgrade to Monte Carlo sim if bots feel too passive.
    if (ctx.tricksRemaining > 6) return false;
  }

  return true;
}

PlayingCard _cheapestTrumpThatWins(List<PlayingCard> trumpCards, _BotContext ctx) {
  final sortedTrump = List.of(trumpCards)
    ..sort((a, b) => a.rank.value.compareTo(b.rank.value));

  if (ctx.trick == null || ctx.trick!.plays.isEmpty) return sortedTrump.first;

  final winner = trickWinner(ctx.trick!.plays, ctx.leadSuit!, ctx.trumpSuit);
  // If current winner is also trump, we need to beat it
  if (winner.card.suit == ctx.trumpSuit) {
    final canBeat = sortedTrump
        .where((c) => c.rank.value > winner.card.rank.value)
        .toList();
    if (canBeat.isNotEmpty) return canBeat.first;
    // Can't beat the existing trump — don't waste ours, sluff instead
    // (caller handles fallback)
    return sortedTrump.first;
  }
  return sortedTrump.first;
}

/// §8.3: Discard when not trumping.
PlayingCard _chooseSluff(List<PlayingCard> cards, _BotContext ctx) {
  // Never sluff a 10 if avoidable
  final nonTen = cards.where((c) => !c.isTen).toList();
  if (nonTen.isNotEmpty) {
    nonTen.sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return nonTen.first;
  }
  // Forced to sluff a 10 — if partner is winning, it's safe
  cards.sort((a, b) => a.rank.value.compareTo(b.rank.value));
  return cards.first;
}
