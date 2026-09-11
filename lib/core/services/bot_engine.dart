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

  Set<int> opponentsKnownVoidIn(Suit suit) {
    final result = <int>{};
    for (final seat in [1, 2, 3, 4]) {
      if (seat == botSeat || seat == partnerSeat) continue;
      if (memory.knownVoidSuits[seat]!.contains(suit)) result.add(seat);
    }
    return result;
  }

  bool partnerKnownVoidIn(Suit suit) =>
      memory.knownVoidSuits[partnerSeat]!.contains(suit);

  List<PlayingCard> unseenInSuit(Suit suit) {
    final allInSuit = PlayingCard.fullDeck.where((c) => c.suit == suit);
    return allInSuit.where((c) => !cardsAccountedFor.contains(c.id)).toList();
  }

  int higherCardsUnseen(Suit suit, Rank rank) =>
      unseenInSuit(suit).where((c) => c.rank.value > rank.value).length;

  bool isCardUnseen(String cardId) => !cardsAccountedFor.contains(cardId);

  bool tenIsLive(Suit suit) {
    final tenId = '10${suit.letter}';
    if (collectedTens.tens[tenId] != null) return false;
    return isCardUnseen(tenId);
  }

  bool get isEndgame => tricksRemaining <= 3;

  int cardsInHand(Suit suit) => allCards.where((c) => c.suit == suit).length;

  bool isVoidIn(Suit suit) => cardsInHand(suit) == 0;

  bool suitIsDead(Suit suit) {
    // A suit is "dead" if we are void and partner is known void,
    // so sluffing low cards in it is safe.
    if (!isVoidIn(suit)) return false;
    return partnerKnownVoidIn(suit);
  }

  bool opponentCouldBeatCard(PlayingCard card) {
    // Assumes card is being played in a non-trump context or as trump.
    // Returns true if any opponent may still hold a higher card of the same suit.
    return higherCardsUnseen(card.suit, card.rank) > 0;
  }

  bool get isLastToAct {
    if (trick == null) return false;
    return trick!.plays.length == 3;
  }

  List<int> get laterSeats {
    if (trick == null) return [];
    final played = trick!.plays.length;
    final seats = <int>[];
    var seat = botSeat;
    for (var i = played; i < 4; i++) {
      seat = GameState.nextSeat(seat);
      seats.add(seat);
    }
    return seats;
  }

  bool laterOpponentCanBeat(TrickPlay currentWinner) {
    for (final seat in laterSeats) {
      if (!isOpponentSeat(seat)) continue;
      if (higherCardsUnseen(currentWinner.card.suit, currentWinner.card.rank) >
          0) {
        return true;
      }
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
  if (diff == BotDifficulty.hard) {
    final hardChoice = _hardSmartLead(legal, ctx);
    if (hardChoice != null) return hardChoice;
  }

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

PlayingCard? _hardSmartLead(List<PlayingCard> legal, _BotContext ctx) {
  // 1. Partner-ruff setup: lead cheapest non-10 from a suit partner is void in,
  //    as long as opponents aren't also known void (which would let them trump).
  final ruffSetupSuits = <Suit>{};
  for (final suit in Suit.values) {
    if (suit == ctx.trumpSuit) continue;
    if (!ctx.partnerKnownVoidIn(suit)) continue;
    if (ctx.opponentsKnownVoidIn(suit).isNotEmpty) continue;
    if (ctx.cardsInHand(suit) > 0) ruffSetupSuits.add(suit);
  }
  if (ruffSetupSuits.isNotEmpty) {
    final candidates = legal
        .where((c) => ruffSetupSuits.contains(c.suit) && !c.isTen)
        .toList()
      ..sort((a, b) => a.rank.value.compareTo(b.rank.value));
    if (candidates.isNotEmpty) return candidates.first;
  }

  // 2. Trump-drawing lead: if we hold high trump and opponents still have trump,
  //    lead a cheap trump to draw theirs out.
  if (ctx.trumpEstablished && ctx.trumpSuit != null) {
    final trumpInHand = ctx.allCards.where((c) => c.suit == ctx.trumpSuit).toList()
      ..sort((a, b) => b.rank.value.compareTo(a.rank.value));
    final hasHighTrump = trumpInHand.isNotEmpty &&
        (trumpInHand.first.rank == Rank.ace || trumpInHand.first.rank == Rank.king);
    final unseenTrumps = ctx.unseenInSuit(ctx.trumpSuit!).length;
    if (hasHighTrump && unseenTrumps > 0 && trumpInHand.length >= 2) {
      final cheapTrump = trumpInHand.last;
      // Don't lead a 10 of trump unless it's our last trump
      if (!cheapTrump.isTen || trumpInHand.length == 1) return cheapTrump;
    }
  }

  // 3. Safe 10 lead (existing logic, but more strict)
  final safeTens = legal
      .where((c) => c.isTen && _isLeadingTenSafe(c, ctx, legal))
      .toList();
  if (safeTens.isNotEmpty) return safeTens.first;

  // 4. Ace-to-ten setup: prefer aces where partner isn't void and opponents
  //    aren't known void, so the 10 lead next trick is safer.
  final acesSettingUpTen = legal
      .where((c) =>
          c.rank == Rank.ace &&
          ctx.allCards.any((h) => h.isTen && h.suit == c.suit))
      .toList();
  if (acesSettingUpTen.isNotEmpty) {
    acesSettingUpTen.sort((a, b) {
      final aRisk = (ctx.partnerKnownVoidIn(a.suit) ? 1 : 0) +
          ctx.opponentsKnownVoidIn(a.suit).length;
      final bRisk = (ctx.partnerKnownVoidIn(b.suit) ? 1 : 0) +
          ctx.opponentsKnownVoidIn(b.suit).length;
      return aRisk.compareTo(bRisk);
    });
    return acesSettingUpTen.first;
  }

  // 5. Avoid leading suits where opponents are known void (they can trump)
  final safe = legal.where((c) => !c.isTen).toList();
  final pool = safe.isNotEmpty ? safe : legal;
  var candidates = pool.where((c) => c.suit != ctx.trumpSuit).toList();
  if (candidates.isEmpty) candidates = pool.toList();
  candidates = candidates
      .where((c) => ctx.opponentsKnownVoidIn(c.suit).isEmpty)
      .toList();
  if (candidates.isEmpty) candidates = pool.toList();

  // 6. Endgame: lead a guaranteed winner if possible
  if (ctx.isEndgame) {
    final guaranteedWinners = candidates.where((c) {
      if (c.suit == ctx.trumpSuit) {
        return ctx.higherCardsUnseen(c.suit, c.rank) == 0;
      }
      // Non-trump winner only if no unseen trump and no higher card in suit
      if (ctx.trumpSuit != null &&
          ctx.unseenInSuit(ctx.trumpSuit!).isNotEmpty) {
        return false;
      }
      return ctx.higherCardsUnseen(c.suit, c.rank) == 0;
    }).toList();
    if (guaranteedWinners.isNotEmpty) {
      guaranteedWinners.sort((a, b) => a.rank.value.compareTo(b.rank.value));
      return guaranteedWinners.first;
    }
  }

  // 7. Lead high card from longest suit (existing behavior)
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
  if (diff == BotDifficulty.hard) {
    final hardChoice = _hardFollowSuit(legal, ctx);
    if (hardChoice != null) return hardChoice;
  }

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

PlayingCard? _hardFollowSuit(List<PlayingCard> legal, _BotContext ctx) {
  final sorted = List.of(legal)
    ..sort((a, b) => b.rank.value.compareTo(a.rank.value));
  final winner = trickWinner(ctx.trick!.plays, ctx.leadSuit!, ctx.trumpSuit);

  // Helper: cheapest card that beats the current winner
  PlayingCard? cheapestWinner() {
    final canWin = sorted
        .where((c) => _beatsCurrentWinner(c, winner, ctx))
        .toList();
    return canWin.isNotEmpty ? canWin.last : null;
  }

  if (ctx.isPartnerWinning) {
    final partnerCard = ctx.trick!.plays.lastWhere(
      (p) => GameState.teamForSeat(p.seat) == ctx.botTeam,
    );

    // Cover partner if a later opponent might beat them and the trick matters
    final trickMatters = ctx.trickHasTen || ctx.isEndgame;
    if (trickMatters &&
        ctx.laterOpponentCanBeat(partnerCard) &&
        ctx.laterSeats.any((s) => ctx.isOpponentSeat(s))) {
      final cover = cheapestWinner();
      if (cover != null) return cover;
    }

    // Duck with lowest non-10
    final safe = sorted.where((c) => !c.isTen).toList();
    return safe.isNotEmpty ? safe.last : sorted.last;
  }

  // Opponent is winning
  final trickMatters = ctx.trickHasTen || ctx.isEndgame;

  if (trickMatters) {
    final win = cheapestWinner();
    if (win != null) return win;
  }

  // Don't waste high cards on meaningless tricks early
  if (!ctx.isEndgame && !ctx.trickHasTen) {
    final safe = sorted.where((c) => !c.isTen).toList();
    return safe.isNotEmpty ? safe.last : sorted.last;
  }

  // Default: cheapest winner if any, else dump
  final win = cheapestWinner();
  if (win != null) return win;
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

  if (diff == BotDifficulty.hard) {
    return _hardPlayVoid(legal, trumpCards, nonTrump, ctx);
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

PlayingCard _hardPlayVoid(
  List<PlayingCard> legal,
  List<PlayingCard> trumpCards,
  List<PlayingCard> nonTrump,
  _BotContext ctx,
) {
  // Never trump partner's winner
  if (ctx.isPartnerWinning) {
    return _hardChooseSluff(nonTrump.isNotEmpty ? nonTrump : legal, ctx);
  }

  final winner = ctx.trick != null && ctx.trick!.plays.isNotEmpty
      ? trickWinner(ctx.trick!.plays, ctx.leadSuit!, ctx.trumpSuit)
      : null;

  // Trump to capture an opponent's ten or win a critical endgame trick
  if (trumpCards.isNotEmpty && winner != null) {
    final opponentWinning = ctx.isOpponentSeat(winner.seat);

    if (opponentWinning && (ctx.trickHasTen || ctx.isEndgame)) {
      final winningTrump = _cheapestTrumpThatWins(trumpCards, ctx);
      // Verify it actually wins
      if (winningTrump.suit == ctx.trumpSuit) {
        if (winner.card.suit == ctx.trumpSuit) {
          if (winningTrump.rank.value > winner.card.rank.value) {
            return winningTrump;
          }
        } else {
          return winningTrump;
        }
      }
    }

    // Last to act: trump a meaningful opponent-winning trick
    if (opponentWinning &&
        ctx.isLastToAct &&
        (ctx.trickHasTen || ctx.isEndgame)) {
      final winningTrump = _cheapestTrumpThatWins(trumpCards, ctx);
      if (winner.card.suit != ctx.trumpSuit) return winningTrump;
      if (winningTrump.rank.value > winner.card.rank.value) {
        return winningTrump;
      }
    }
  }

  // Sluff
  return _hardChooseSluff(nonTrump.isNotEmpty ? nonTrump : legal, ctx);
}

PlayingCard _hardChooseSluff(List<PlayingCard> cards, _BotContext ctx) {
  // Never sluff a 10 if avoidable
  var pool = cards.where((c) => !c.isTen).toList();
  if (pool.isEmpty) pool = cards;

  // Prefer sluffing from dead suits (both we and partner are void, so no value)
  final deadSuitCards = pool.where((c) => ctx.suitIsDead(c.suit)).toList();
  if (deadSuitCards.isNotEmpty) {
    deadSuitCards.sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return deadSuitCards.first;
  }

  // Avoid sluffing from trump
  final nonTrump = pool.where((c) => c.suit != ctx.trumpSuit).toList();
  final sluffPool = nonTrump.isNotEmpty ? nonTrump : pool;

  // Sluff from shortest side suit to create voids fastest
  final bySuit = <Suit, List<PlayingCard>>{};
  for (final c in sluffPool) {
    bySuit.putIfAbsent(c.suit, () => []).add(c);
  }
  final shortest = bySuit.entries.toList()
    ..sort((a, b) => a.value.length.compareTo(b.value.length));
  if (shortest.isNotEmpty) {
    final suitCards = shortest.first.value
      ..sort((a, b) => a.rank.value.compareTo(b.rank.value));
    return suitCards.first;
  }

  return sluffPool.reduce((a, b) => a.rank.value <= b.rank.value ? a : b);
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
    suitScores[card.suit] = diff == BotDifficulty.hard
        ? _evaluateTrumpSuitQualityHard(card.suit, ctx)
        : _evaluateTrumpSuitQuality(card.suit, ctx);
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

double _evaluateTrumpSuitQualityHard(Suit suit, _BotContext ctx) {
  final cardsInSuit = ctx.allCards.where((c) => c.suit == suit).toList();
  var score = 0.0;

  // Length and high cards
  score += cardsInSuit.length * 2.5;
  for (final c in cardsInSuit) {
    if (c.rank == Rank.ace) score += 6.0;
    if (c.rank == Rank.king) score += 4.0;
    if (c.rank == Rank.queen) score += 2.5;
    if (c.rank == Rank.jack) score += 1.5;
  }

  // Holding the 10 of the proposed trump is huge
  if (cardsInSuit.any((c) => c.isTen)) score += 8.0;

  // Penalize if partner is known void — they cannot help draw trump or ruff
  if (ctx.partnerKnownVoidIn(suit)) score -= 4.0;

  // Reward if opponents are known void — our side suits are more ruffable
  score += ctx.opponentsKnownVoidIn(suit).length * 3.0;

  // Penalize unseen cards in the suit (we don't yet control it)
  score -= ctx.unseenInSuit(suit).length * 0.5;

  // Bonus for side aces that let us regain lead and cash 10s
  for (final c in ctx.allCards) {
    if (c.suit == suit) continue;
    if (c.rank == Rank.ace) score += 1.0;
  }

  // If current trick contains an opponent's 10 and this suit would win it,
  // strongly prefer this suit
  if (ctx.trick != null && ctx.trick!.plays.isNotEmpty) {
    final leadSuit = ctx.leadSuit ?? ctx.trick!.plays.first.card.suit;
    if (ctx.trickHasTen && suit != leadSuit) {
      final wouldWin = ctx.trick!.plays.every((p) =>
          p.card.suit != suit ||
          cardsInSuit.isEmpty ||
          cardsInSuit.first.rank.value > p.card.rank.value);
      if (wouldWin) score += 20.0;
    }
  }

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
