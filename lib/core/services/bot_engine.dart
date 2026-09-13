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
    for (final suits in knownVoidSuits.values) {
      suits.clear();
    }
    playHistory.clear();
  }

  Set<String> get allPlayedCardIds =>
      playHistory.map((play) => play.card.id).toSet();
}

class BotFactorScore {
  final String factor;
  final double contribution;
  final String reason;

  const BotFactorScore({
    required this.factor,
    required this.contribution,
    required this.reason,
  });
}

class BotCardEvaluation {
  final PlayingCard card;
  final double totalScore;
  final List<BotFactorScore> breakdown;

  const BotCardEvaluation({
    required this.card,
    required this.totalScore,
    required this.breakdown,
  });
}

class BotDecision {
  final BotCardEvaluation selected;
  final List<BotCardEvaluation> evaluations;

  const BotDecision({required this.selected, required this.evaluations});

  PlayingCard get card => selected.card;

  String get trace {
    final factors = [...selected.breakdown]
      ..sort((a, b) => b.contribution.abs().compareTo(a.contribution.abs()));
    final topFactors = factors.take(3);
    final buffer = StringBuffer('Selected: ${selected.card.id}\n\nReason:\n');
    for (final factor in topFactors) {
      final sign = factor.contribution >= 0 ? '+' : '';
      buffer.writeln(
        '- ${factor.reason} (${factor.factor}: '
        '$sign${factor.contribution.toStringAsFixed(2)})',
      );
    }
    buffer.write('Total score: ${selected.totalScore.toStringAsFixed(2)}');
    return buffer.toString();
  }
}

String chooseBotCard({
  required List<String> hand,
  required GameState gameState,
  required int botSeat,
  BotDifficulty difficulty = BotDifficulty.medium,
  BotMemory? memory,
  Random? random,
  void Function(String trace)? debugLog,
}) => evaluateBotDecision(
  hand: hand,
  gameState: gameState,
  botSeat: botSeat,
  difficulty: difficulty,
  memory: memory,
  random: random,
  debugLog: debugLog,
).card.id;

BotDecision evaluateBotDecision({
  required List<String> hand,
  required GameState gameState,
  required int botSeat,
  BotDifficulty difficulty = BotDifficulty.medium,
  BotMemory? memory,
  Random? random,
  void Function(String trace)? debugLog,
}) {
  final cards = hand.map(PlayingCard.fromId).toList();
  final trick = gameState.currentTrick;
  final isLeading = trick == null || trick.plays.isEmpty;
  final leadSuit = isLeading
      ? null
      : (gameState.leadSuit ?? trick.plays.first.card.suit);
  final legalCards = getLegalCards(cards, leadSuit);

  if (legalCards.length == 1) {
    final evaluation = BotCardEvaluation(
      card: legalCards.single,
      totalScore: 0,
      breakdown: const [
        BotFactorScore(
          factor: 'forced_move',
          contribution: 0,
          reason: 'Only one legal card is available.',
        ),
      ],
    );
    final decision = BotDecision(
      selected: evaluation,
      evaluations: [evaluation],
    );
    debugLog?.call(decision.trace);
    return decision;
  }

  final context = _DecisionContext(
    botSeat: botSeat,
    botTeam: GameState.teamForSeat(botSeat),
    trick: trick,
    leadSuit: leadSuit,
    trumpSuit: gameState.trumpSuit,
    trickNumber: gameState.trickNumber,
    collectedTens: gameState.collectedTens,
    trickPileA: gameState.trickPileA,
    trickPileB: gameState.trickPileB,
    memory: memory ?? BotMemory(),
    allCards: cards,
    legalCards: legalCards,
    difficulty: difficulty,
  );
  final weights = _BotWeights.forDifficulty(difficulty);
  final candidates = _trumpEstablishingCandidates(context);
  final rng = random ?? Random();
  final simulated = weights.simulationSamples > 0
      ? _simulateCandidates(
          candidates: candidates,
          game: gameState,
          context: context,
          samples: weights.simulationSamples,
          random: rng,
        )
      : const <PlayingCard, double>{};
  final evaluations =
      candidates
          .map(
            (card) => _evaluateCard(
              card: card,
              context: context,
              weights: weights,
              random: rng,
              simulated: simulated[card],
            ),
          )
          .toList()
        ..sort(_compareEvaluations);

  final decision = BotDecision(
    selected: evaluations.first,
    evaluations: evaluations,
  );
  debugLog?.call(decision.trace);
  return decision;
}

class _DecisionContext {
  final int botSeat;
  final String botTeam;
  final CurrentTrick? trick;
  final Suit? leadSuit;
  final Suit? trumpSuit;
  final int trickNumber;
  final CollectedTens collectedTens;
  final TrickPile trickPileA;
  final TrickPile trickPileB;
  final BotMemory memory;
  final List<PlayingCard> allCards;
  final List<PlayingCard> legalCards;
  final BotDifficulty difficulty;

  _DecisionContext({
    required this.botSeat,
    required this.botTeam,
    required this.trick,
    required this.leadSuit,
    required this.trumpSuit,
    required this.trickNumber,
    required this.collectedTens,
    required this.trickPileA,
    required this.trickPileB,
    required this.memory,
    required this.allCards,
    required this.legalCards,
    required this.difficulty,
  });

  bool get isLeading => trick == null || trick!.plays.isEmpty;
  bool get trumpEstablished => trumpSuit != null;
  bool get isEndgame => tricksRemaining <= 3;
  bool get isLastTrick => tricksRemaining == 1;
  int get tricksRemaining => 14 - trickNumber;
  int get partnerSeat => GameState.partnerSeat(botSeat);

  List<TrickPlay> get currentPlays => trick?.plays ?? const [];

  TrickPlay? get currentWinner =>
      isLeading ? null : trickWinner(currentPlays, leadSuit!, trumpSuit);

  bool get currentWinnerIsPartner =>
      currentWinner != null &&
      GameState.teamForSeat(currentWinner!.seat) == botTeam;

  bool get currentWinnerIsOpponent =>
      currentWinner != null &&
      GameState.teamForSeat(currentWinner!.seat) != botTeam;

  bool get trickHasTen => currentPlays.any((play) => play.card.isTen);

  List<int> get laterSeats {
    final remainingSeats = 3 - currentPlays.length;
    var seat = botSeat;
    final seats = <int>[];
    for (var i = 0; i < remainingSeats; i++) {
      seat = GameState.nextSeat(seat);
      seats.add(seat);
    }
    return seats;
  }

  List<int> get laterOpponentSeats => laterSeats.where(isOpponentSeat).toList();

  bool get isLastToAct => laterSeats.isEmpty;

  bool isOpponentSeat(int seat) => GameState.teamForSeat(seat) != botTeam;

  int cardsInHand(Suit suit) =>
      allCards.where((card) => card.suit == suit).length;

  int higherCardsUnseen(Suit suit, Rank rank) => cardsUnseen
      .where((card) => card.suit == suit && card.rank.value > rank.value)
      .length;

  late final List<PlayingCard> cardsUnseen = () {
    final accountedFor = <String>{
      ...allCards.map((card) => card.id),
      ...trickPileA.cards,
      ...trickPileB.cards,
      ...currentPlays.map((play) => play.card.id),
    };
    return PlayingCard.fullDeck
        .where((card) => !accountedFor.contains(card.id))
        .toList();
  }();

  /// Memory only records completed tricks, so also read voids off this trick.
  bool isKnownVoid(int seat, Suit suit) =>
      (memory.knownVoidSuits[seat]?.contains(suit) ?? false) ||
      (leadSuit == suit &&
          currentPlays.any((p) => p.seat == seat && p.card.suit != suit));

  bool partnerKnownVoidIn(Suit suit) => isKnownVoid(partnerSeat, suit);

  int opponentsKnownVoidIn(Suit suit) => [
    1,
    2,
    3,
    4,
  ].where((seat) => isOpponentSeat(seat) && isKnownVoid(seat, suit)).length;

  bool get opponentKnownVoidInLead =>
      leadSuit != null && opponentsKnownVoidIn(leadSuit!) > 0;

  int get myTeamTenCount => collectedTens.tensForTeam(botTeam);

  int get opponentTeamTenCount =>
      collectedTens.tensForTeam(botTeam == 'teamA' ? 'teamB' : 'teamA');

  int get tensStillUnresolved =>
      collectedTens.tens.values.where((team) => team == null).length;

  Set<String> get playedCardIds => {
    ...trickPileA.cards,
    ...trickPileB.cards,
    ...currentPlays.map((play) => play.card.id),
  };

  Suit? projectedTrump(PlayingCard card) {
    if (trumpSuit != null) return trumpSuit;
    if (!isLeading && card.suit != leadSuit) return card.suit;
    return null;
  }

  Suit projectedLead(PlayingCard card) => leadSuit ?? card.suit;

  List<TrickPlay> playsAfter(PlayingCard card) => [
    ...currentPlays,
    TrickPlay(botSeat, card),
  ];

  bool wouldWinNow(PlayingCard card) {
    final plays = playsAfter(card);
    return trickWinner(plays, projectedLead(card), projectedTrump(card)).seat ==
        botSeat;
  }

  bool isTrump(PlayingCard card) => projectedTrump(card) == card.suit;

  bool get isHighValueTrick => trickHasTen || isEndgame;

  bool hasSafeNonTenDiscard() {
    if (isLeading) return false;
    return legalCards.any((card) {
      if (card.isTen) return false;
      if (currentWinnerIsPartner) return !wouldWinNow(card);
      return !wouldWinNow(card);
    });
  }

  List<PlayingCard> get winningLegalCards =>
      legalCards.where(wouldWinNow).toList();
}

class _BotWeights {
  final double leadStrength;
  final double overtakePartnerPenalty;
  final double duckSmallBonus;
  final double winTrickBonus;
  final double securePartnerLead;
  final double tenSafeDisposal;
  final double preferOtherDiscard;
  final double tenCaptureBonus;
  final double avoidFeedingOpponentTen;
  final double forcedTenSacrifice;
  final double trumpBase;
  final double strongTrumpThreshold;
  final double strongTrumpMultiplier;
  final double trumpForcedBonus;
  final double trumpWinsImportantTrick;
  final double trumpProtectsPartner;
  final double trumpEndgameRelease;
  final double highCardRetention;
  final double voidCreationValue;
  final double tenRetentionWhenProtected;
  final double tenLeadRisk;
  final double tenSetupLead;
  final double overtakeRiskPenalty;
  final double tenUrgencyHigh;
  final double tenUrgencyLow;
  final double jitterMagnitude;

  /// Hidden-hand samples played out per decision; 0 disables simulation.
  final int simulationSamples;
  final double simulationWeight;

  const _BotWeights({
    this.simulationSamples = 0,
    this.simulationWeight = 0,
    required this.leadStrength,
    required this.overtakePartnerPenalty,
    required this.duckSmallBonus,
    required this.winTrickBonus,
    required this.securePartnerLead,
    required this.tenSafeDisposal,
    required this.preferOtherDiscard,
    required this.tenCaptureBonus,
    required this.avoidFeedingOpponentTen,
    required this.forcedTenSacrifice,
    required this.trumpBase,
    required this.strongTrumpThreshold,
    required this.strongTrumpMultiplier,
    required this.trumpForcedBonus,
    required this.trumpWinsImportantTrick,
    required this.trumpProtectsPartner,
    required this.trumpEndgameRelease,
    required this.highCardRetention,
    required this.voidCreationValue,
    required this.tenRetentionWhenProtected,
    required this.tenLeadRisk,
    required this.tenSetupLead,
    required this.overtakeRiskPenalty,
    required this.tenUrgencyHigh,
    required this.tenUrgencyLow,
    required this.jitterMagnitude,
  });

  static const _easy = _BotWeights(
    leadStrength: 0.25,
    overtakePartnerPenalty: 0.4,
    duckSmallBonus: 0.1,
    winTrickBonus: 0.45,
    securePartnerLead: 0.1,
    tenSafeDisposal: 0.3,
    preferOtherDiscard: 0.5,
    tenCaptureBonus: 0.5,
    avoidFeedingOpponentTen: 0.7,
    forcedTenSacrifice: 0.2,
    trumpBase: 0.55,
    strongTrumpThreshold: 0.75,
    strongTrumpMultiplier: 1.25,
    trumpForcedBonus: 0.3,
    trumpWinsImportantTrick: 0.6,
    trumpProtectsPartner: 0.25,
    trumpEndgameRelease: 0.2,
    highCardRetention: 0.15,
    voidCreationValue: 0.1,
    tenRetentionWhenProtected: 0.2,
    tenLeadRisk: 0.2,
    tenSetupLead: 0.25,
    overtakeRiskPenalty: 0.15,
    tenUrgencyHigh: 0.2,
    tenUrgencyLow: 0.08,
    jitterMagnitude: 0.8,
  );

  static const _medium = _BotWeights(
    leadStrength: 0.45,
    overtakePartnerPenalty: 0.85,
    duckSmallBonus: 0.18,
    winTrickBonus: 0.85,
    securePartnerLead: 0.35,
    tenSafeDisposal: 0.75,
    preferOtherDiscard: 0.9,
    tenCaptureBonus: 1.35,
    avoidFeedingOpponentTen: 1.5,
    forcedTenSacrifice: 0.5,
    trumpBase: 1.0,
    strongTrumpThreshold: 0.75,
    strongTrumpMultiplier: 1.7,
    trumpForcedBonus: 0.4,
    trumpWinsImportantTrick: 1.6,
    trumpProtectsPartner: 0.5,
    trumpEndgameRelease: 0.6,
    highCardRetention: 0.5,
    voidCreationValue: 0.35,
    tenRetentionWhenProtected: 0.55,
    tenLeadRisk: 0.7,
    tenSetupLead: 0.9,
    overtakeRiskPenalty: 0.55,
    tenUrgencyHigh: 0.6,
    tenUrgencyLow: 0.25,
    jitterMagnitude: 0.25,
  );

  static const _hard = _BotWeights(
    leadStrength: 0.65,
    overtakePartnerPenalty: 1.35,
    duckSmallBonus: 0.25,
    winTrickBonus: 1.1,
    securePartnerLead: 0.65,
    tenSafeDisposal: 1.15,
    preferOtherDiscard: 1.4,
    tenCaptureBonus: 1.9,
    avoidFeedingOpponentTen: 2.2,
    forcedTenSacrifice: 0.7,
    trumpBase: 1.4,
    strongTrumpThreshold: 0.75,
    strongTrumpMultiplier: 2.2,
    trumpForcedBonus: 0.45,
    trumpWinsImportantTrick: 2.2,
    trumpProtectsPartner: 0.75,
    trumpEndgameRelease: 1.0,
    highCardRetention: 0.75,
    voidCreationValue: 0.5,
    tenRetentionWhenProtected: 0.85,
    tenLeadRisk: 1.0,
    tenSetupLead: 1.2,
    overtakeRiskPenalty: 0.9,
    tenUrgencyHigh: 0.9,
    tenUrgencyLow: 0.35,
    jitterMagnitude: 0.03,
    // Tuned in self-play: more samples or a heavier weight did not win more.
    simulationSamples: 16,
    simulationWeight: 3,
  );

  static _BotWeights forDifficulty(BotDifficulty difficulty) {
    switch (difficulty) {
      case BotDifficulty.easy:
        return _easy;
      case BotDifficulty.medium:
        return _medium;
      case BotDifficulty.hard:
        return _hard;
    }
  }
}

BotCardEvaluation _evaluateCard({
  required PlayingCard card,
  required _DecisionContext context,
  required _BotWeights weights,
  required Random random,
  double? simulated,
}) {
  final breakdown = <BotFactorScore>[
    _scoreImmediateOutcome(card, context, weights),
    _scoreTeamPosition(card, context, weights),
    _scoreTenManagement(card, context, weights),
    _scoreTrumpPreservation(card, context, weights),
    _scoreFutureValue(card, context, weights),
    _scoreOvertakeRisk(card, context, weights),
    _scoreTeamBenefit(card, context, weights),
    _scoreRandomJitter(weights, random),
    if (simulated != null)
      BotFactorScore(
        factor: 'simulation',
        contribution: weights.simulationWeight * simulated,
        reason:
            'Played out ${weights.simulationSamples} sampled deals: '
            'average result ${simulated.toStringAsFixed(2)} (-1.4 lose .. +1.4 win).',
      ),
  ];
  final total = breakdown.fold<double>(
    0,
    (score, factor) => score + factor.contribution,
  );
  return BotCardEvaluation(
    card: card,
    totalScore: total,
    breakdown: List.unmodifiable(breakdown),
  );
}

BotFactorScore _scoreImmediateOutcome(
  PlayingCard card,
  _DecisionContext context,
  _BotWeights weights,
) {
  if (context.isLeading) {
    return BotFactorScore(
      factor: 'immediate_outcome',
      contribution: weights.leadStrength * _normalizedRank(card),
      reason: 'Leading card has a rank-scaled baseline.',
    );
  }

  final wouldWin = context.wouldWinNow(card);
  if (context.currentWinnerIsPartner) {
    // A ten lands in the trick either way, so topping partner with it wastes
    // nothing — only higher cards are "spent" by an overtake.
    if (wouldWin && !card.isTen) {
      return BotFactorScore(
        factor: 'immediate_outcome',
        contribution: -weights.overtakePartnerPenalty,
        reason: 'Would unnecessarily overtake the partner\'s winning card.',
      );
    }
    return BotFactorScore(
      factor: 'immediate_outcome',
      contribution: weights.duckSmallBonus,
      reason: 'Ducking under the partner\'s winning card is the default.',
    );
  }

  if (context.currentWinnerIsOpponent && wouldWin) {
    return BotFactorScore(
      factor: 'immediate_outcome',
      contribution: weights.winTrickBonus,
      reason: 'Would take the current trick back from an opponent.',
    );
  }

  return const BotFactorScore(
    factor: 'immediate_outcome',
    contribution: 0,
    reason: 'Cannot improve the opponent\'s current winning card.',
  );
}

BotFactorScore _scoreTeamPosition(
  PlayingCard card,
  _DecisionContext context,
  _BotWeights weights,
) {
  if (context.isLeading ||
      context.isLastToAct ||
      !context.currentWinnerIsPartner) {
    return const BotFactorScore(
      factor: 'team_position',
      contribution: 0,
      reason: 'No additional team-position pressure applies.',
    );
  }

  final candidateWins = context.wouldWinNow(card);
  final partnerRisk = _estimateOvertakeProbabilityForCurrentWinner(context);
  final candidateRisk = _estimateOvertakeProbability(card, context);
  if (candidateWins && partnerRisk >= 0.5 && candidateRisk < partnerRisk) {
    return BotFactorScore(
      factor: 'team_position',
      contribution: weights.securePartnerLead,
      reason: 'A lower-risk overtake secures the partner\'s threatened lead.',
    );
  }

  return const BotFactorScore(
    factor: 'team_position',
    contribution: 0,
    reason: 'The partner\'s lead does not need extra protection.',
  );
}

BotFactorScore _scoreTenManagement(
  PlayingCard card,
  _DecisionContext context,
  _BotWeights weights,
) {
  if (!card.isTen) {
    return const BotFactorScore(
      factor: 'ten_management',
      contribution: 0,
      reason: 'Not a ten, so no direct ten-management pressure applies.',
    );
  }

  final risk = (context.isLeading || context.wouldWinNow(card))
      ? _estimateOvertakeProbability(card, context)
      : _estimateOvertakeProbabilityForCurrentWinner(context);
  // +1 when the ten is sure to stay with us, -1 when it is sure to be lost.
  final security = 1 - 2 * risk;
  final riskText = '${(risk * 100).round()}% overtake risk';

  if (context.isLeading) {
    return BotFactorScore(
      factor: 'ten_management',
      contribution: security > 0
          ? weights.tenSafeDisposal * security
          : weights.tenLeadRisk * security,
      reason: 'Leading this ten ($riskText).',
    );
  }

  final safeDiscardExists = context.hasSafeNonTenDiscard();
  if (context.currentWinnerIsPartner) {
    if (security > 0) {
      return BotFactorScore(
        factor: 'ten_management',
        contribution: weights.tenSafeDisposal * security,
        reason: 'Banks the ten on the partner\'s trick ($riskText).',
      );
    }
    return BotFactorScore(
      factor: 'ten_management',
      contribution:
          (safeDiscardExists
              ? weights.preferOtherDiscard
              : weights.forcedTenSacrifice) *
          security,
      reason: 'The partner\'s trick is likely to be overtaken ($riskText).',
    );
  }

  if (context.currentWinnerIsOpponent) {
    final tenWins = context.wouldWinNow(card);
    if (tenWins) {
      final cheapest = _cheapestWinningCard(context) == card;
      return BotFactorScore(
        factor: 'ten_management',
        contribution: weights.tenCaptureBonus * security * (cheapest ? 1 : 0.5),
        reason: 'This ten recaptures the trick ($riskText).',
      );
    }
    if (!tenWins && safeDiscardExists) {
      return BotFactorScore(
        factor: 'ten_management',
        contribution: -weights.avoidFeedingOpponentTen,
        reason: 'This ten cannot win and a safer discard avoids feeding it to opponents.',
      );
    }
    if (!tenWins) {
      return BotFactorScore(
        factor: 'ten_management',
        contribution: -weights.forcedTenSacrifice,
        reason: 'No other safe discard exists, so this ten must be sacrificed.',
      );
    }
  }

  return const BotFactorScore(
    factor: 'ten_management',
    contribution: 0,
    reason: 'No direct ten-management signal applies.',
  );
}

BotFactorScore _scoreTrumpPreservation(
  PlayingCard card,
  _DecisionContext context,
  _BotWeights weights,
) {
  if (!context.isTrump(card)) {
    return const BotFactorScore(
      factor: 'trump_preservation',
      contribution: 0,
      reason: 'Not a trump card.',
    );
  }

  final normalizedRank = _normalizedRank(card);
  final strongTrump = normalizedRank >= weights.strongTrumpThreshold;
  final reservationMultiplier = strongTrump
      ? weights.strongTrumpMultiplier
      : 1 + normalizedRank * 0.5;
  final basePenalty = -weights.trumpBase * reservationMultiplier;
  var justification = 0.0;
  final reasons = <String>[];
  final nonTrumpAlternative = context.legalCards.any(
    (other) => !context.isTrump(other),
  );

  if (!nonTrumpAlternative) {
    justification += weights.trumpForcedBonus;
    reasons.add('no non-trump legal alternative exists');
  }
  if (context.currentWinnerIsOpponent &&
      context.wouldWinNow(card) &&
      context.isHighValueTrick) {
    justification += weights.trumpWinsImportantTrick;
    reasons.add('it recaptures an important opponent trick');
  }
  if (context.currentWinnerIsPartner &&
      context.wouldWinNow(card) &&
      _estimateOvertakeProbabilityForCurrentWinner(context) >= 0.5 &&
      _estimateOvertakeProbability(card, context) <
          _estimateOvertakeProbabilityForCurrentWinner(context)) {
    justification += weights.trumpProtectsPartner;
    reasons.add('it reduces the threat against the partner\'s lead');
  }
  if (context.isEndgame) {
    justification +=
        weights.trumpEndgameRelease * (context.isLastTrick ? 1 : 0.5);
    reasons.add('few tricks remain to preserve trump for');
  }

  return BotFactorScore(
    factor: 'trump_preservation',
    contribution: basePenalty + justification,
    reason: reasons.isEmpty
        ? 'Preserving this ${strongTrump ? 'strong' : 'weak'} trump has more value.'
        : 'Trump play is justified because ${reasons.join('; ')}.',
  );
}

BotFactorScore _scoreFutureValue(
  PlayingCard card,
  _DecisionContext context,
  _BotWeights weights,
) {
  if (context.isTrump(card)) {
    return const BotFactorScore(
      factor: 'future_value',
      contribution: 0,
      reason: 'Trump retention is scored separately.',
    );
  }

  var contribution = 0.0;
  final reasons = <String>[];
  final suitLength = context.cardsInHand(card.suit);
  final higherUnseen = context.higherCardsUnseen(card.suit, card.rank);

  if (card.rank.value >= Rank.jack.value && higherUnseen <= 1) {
    contribution -= weights.highCardRetention;
    reasons.add('it is near the top of its suit and worth retaining');
  }
  if (context.isLeading &&
      card.rank == Rank.ace &&
      context.allCards.any((held) => held.isTen && held.suit == card.suit)) {
    contribution += weights.tenSetupLead;
    reasons.add('it clears the path to cash a held ten later');
  }
  if (suitLength == 1 && !card.isTen && !context.trumpEstablished) {
    contribution += weights.voidCreationValue;
    reasons.add('it creates a future void while trump is unset');
  }
  if (card.isTen && suitLength > 1) {
    contribution -= weights.tenRetentionWhenProtected;
    reasons.add('other cards in this suit can still protect the ten');
  }

  return BotFactorScore(
    factor: 'future_value',
    contribution: contribution,
    reason: reasons.isEmpty
        ? 'No strong future-retention signal applies.'
        : reasons.join('; '),
  );
}

BotFactorScore _scoreOvertakeRisk(
  PlayingCard card,
  _DecisionContext context,
  _BotWeights weights,
) {
  if (context.isLastToAct) {
    return const BotFactorScore(
      factor: 'overtake_risk',
      contribution: 0,
      reason: 'No one remains to overtake this play.',
    );
  }
  if (!context.wouldWinNow(card)) {
    return const BotFactorScore(
      factor: 'overtake_risk',
      contribution: 0,
      reason: 'This card would not be winning now.',
    );
  }

  final probability = _estimateOvertakeProbability(card, context);
  return BotFactorScore(
    factor: 'overtake_risk',
    contribution: -weights.overtakeRiskPenalty * probability,
    reason:
        'Later opponents have an estimated '
        '${(probability * 100).round()}% chance to overtake this play.',
  );
}

BotFactorScore _scoreTeamBenefit(
  PlayingCard card,
  _DecisionContext context,
  _BotWeights weights,
) {
  if (!context.wouldWinNow(card)) {
    return const BotFactorScore(
      factor: 'team_benefit',
      contribution: 0,
      reason: 'This card is not currently winning the trick.',
    );
  }
  if (context.tensStillUnresolved == 0) {
    return const BotFactorScore(
      factor: 'team_benefit',
      contribution: 0,
      reason: 'All tens are already resolved.',
    );
  }

  final urgency = context.opponentTeamTenCount >= context.myTeamTenCount
      ? weights.tenUrgencyHigh
      : weights.tenUrgencyLow;
  final contribution = urgency * (context.trickHasTen ? 1 : 0.3);
  return BotFactorScore(
    factor: 'team_benefit',
    contribution: contribution,
    reason: 'The team\'s ten standing adjusts the value of winning this trick.',
  );
}

BotFactorScore _scoreRandomJitter(_BotWeights weights, Random random) {
  final contribution = (random.nextDouble() * 2 - 1) * weights.jitterMagnitude;
  return BotFactorScore(
    factor: 'jitter',
    contribution: contribution,
    reason: 'Difficulty-scaled decision variability.',
  );
}

List<PlayingCard> _trumpEstablishingCandidates(_DecisionContext context) {
  if (context.isLeading ||
      context.trumpEstablished ||
      context.leadSuit == null) {
    return context.legalCards;
  }
  if (context.legalCards.any((card) => card.suit == context.leadSuit)) {
    return context.legalCards;
  }

  final suits = context.legalCards.map((card) => card.suit).toSet();
  final preferredSuit = suits.reduce((best, candidate) {
    final bestScore = _trumpSuitQuality(best, context);
    final candidateScore = _trumpSuitQuality(candidate, context);
    return candidateScore > bestScore ? candidate : best;
  });
  return context.legalCards
      .where((card) => card.suit == preferredSuit)
      .toList();
}

double _trumpSuitQuality(Suit suit, _DecisionContext context) {
  final cards = context.allCards.where((card) => card.suit == suit).toList();
  var score = cards.length * 3.0;
  for (final card in cards) {
    if (card.rank == Rank.ace) score += 6;
    if (card.rank == Rank.king) score += 4;
    if (card.rank == Rank.queen) score += 2.5;
    if (card.rank == Rank.jack) score += 1.5;
  }
  if (cards.any((card) => card.isTen)) score += 8;
  if (context.partnerKnownVoidIn(suit)) score -= 4;
  score += context.opponentsKnownVoidIn(suit) * 3;
  score -= context.cardsUnseen.where((card) => card.suit == suit).length * 0.5;
  score +=
      context.allCards
          .where((card) => card.suit != suit && card.rank == Rank.ace)
          .length *
      1.0;
  if (context.trickHasTen && suit != context.leadSuit) {
    final candidate = cards.reduce(
      (a, b) => a.rank.value >= b.rank.value ? a : b,
    );
    if (context.wouldWinNow(candidate)) score += 20;
  }
  return score;
}

PlayingCard? _cheapestWinningCard(_DecisionContext context) {
  final winners = context.winningLegalCards;
  if (winners.isEmpty) return null;
  winners.sort((a, b) {
    final trumpComparison = context.isTrump(a) == context.isTrump(b)
        ? 0
        : (context.isTrump(a) ? 1 : -1);
    if (trumpComparison != 0) return trumpComparison;
    return a.rank.value.compareTo(b.rank.value);
  });
  return winners.first;
}

double _normalizedRank(PlayingCard card) => (card.rank.value - 2) / 12;

double _estimateOvertakeProbability(
  PlayingCard card,
  _DecisionContext context,
) => _estimateOvertakeProbabilityFromPlays(
  plays: context.playsAfter(card),
  leadSuit: context.projectedLead(card),
  trumpSuit: context.projectedTrump(card),
  laterOpponentSeats: context.laterOpponentSeats,
  context: context,
);

double _estimateOvertakeProbabilityForCurrentWinner(_DecisionContext context) {
  if (context.currentWinner == null || context.isLastToAct) return 0;
  return _estimateOvertakeProbabilityFromPlays(
    plays: context.currentPlays,
    leadSuit: context.leadSuit!,
    trumpSuit: context.trumpSuit,
    laterOpponentSeats: context.laterOpponentSeats,
    context: context,
  );
}

double _estimateOvertakeProbabilityFromPlays({
  required List<TrickPlay> plays,
  required Suit leadSuit,
  required Suit? trumpSuit,
  required List<int> laterOpponentSeats,
  required _DecisionContext context,
}) {
  if (laterOpponentSeats.isEmpty) return 0;
  final winner = trickWinner(plays, leadSuit, trumpSuit).card;
  final unseen = context.cardsUnseen;
  final n = unseen.length;
  final handSize = 14 - context.trickNumber;
  final winnerIsTrump = winner.suit == trumpSuit;
  final leadCount = unseen.where((c) => c.suit == leadSuit).length;
  final leadThreats = winnerIsTrump
      ? 0
      : unseen
            .where(
              (c) => c.suit == leadSuit && c.rank.value > winner.rank.value,
            )
            .length;
  final trumpThreats = trumpSuit == null
      ? 0
      : unseen
            .where(
              (c) =>
                  c.suit == trumpSuit &&
                  (!winnerIsTrump || c.rank.value > winner.rank.value),
            )
            .length;

  var missChance = 1.0;
  for (final seat in laterOpponentSeats) {
    // Unset trump: whatever a void opponent throws becomes trump and wins.
    final ruff = trumpSuit == null
        ? 1.0
        : context.isKnownVoid(seat, trumpSuit)
        ? 0.0
        : 1 - _noneDrawn(n - leadCount, trumpThreats, handSize);
    final exact = context.isKnownVoid(seat, leadSuit)
        ? ruff
        : 1 -
              _noneDrawn(n, leadThreats, handSize) +
              _noneDrawn(n, leadCount, handSize) * ruff;
    final seatProbability = switch (context.difficulty) {
      BotDifficulty.easy => exact > 0.05 ? 0.25 : 0.0,
      BotDifficulty.medium => min(0.9, exact * 0.8 + 0.05),
      BotDifficulty.hard => exact,
    };
    missChance *= 1 - seatProbability.clamp(0.0, 1.0);
  }
  return 1 - missChance;
}

/// Chance that none of [special] cards land in a [draws]-card hand dealt
/// from [pool] cards (hypergeometric, zero successes).
double _noneDrawn(int pool, int special, int draws) {
  if (special <= 0) return 1;
  if (draws > pool - special) return 0;
  var p = 1.0;
  for (var i = 0; i < draws; i++) {
    p *= (pool - special - i) / (pool - i);
  }
  return p;
}

/// Determinized look-ahead: deal the unseen cards to the other seats in a way
/// consistent with known voids, then play each candidate to the end of the
/// game with the medium policy. Every candidate sees the same samples so the
/// comparison between cards is not drowned in deal-to-deal noise.
// ponytail: fixed sample count on the calling isolate; add a time budget or
// move to an isolate if low-end phones stutter.
Map<PlayingCard, double> _simulateCandidates({
  required List<PlayingCard> candidates,
  required GameState game,
  required _DecisionContext context,
  required int samples,
  required Random random,
}) {
  final totals = {for (final card in candidates) card: 0.0};
  var played = 0;
  for (var i = 0; i < samples; i++) {
    final hidden = _sampleHiddenHands(context, random);
    if (hidden == null) break;
    final seed = random.nextInt(1 << 30);
    for (final card in candidates) {
      final hands = {
        for (final entry in hidden.entries) entry.key: [...entry.value],
        context.botSeat: [...context.allCards]..remove(card),
      };
      final memory = BotMemory();
      context.memory.knownVoidSuits.forEach(
        (seat, suits) => memory.knownVoidSuits[seat]!.addAll(suits),
      );
      totals[card] =
          totals[card]! +
          _playOut(game, context, card, hands, memory, Random(seed));
    }
    played++;
  }
  if (played == 0) return const {};
  return totals.map((card, total) => MapEntry(card, total / played));
}

Map<int, List<PlayingCard>>? _sampleHiddenHands(
  _DecisionContext context,
  Random random,
) {
  final handSize = 14 - context.trickNumber;
  final seats = [
    for (var seat = 1; seat <= 4; seat++)
      if (seat != context.botSeat) seat,
  ];
  final need = {
    for (final seat in seats)
      seat:
          handSize -
          (context.currentPlays.any((play) => play.seat == seat) ? 1 : 0),
  };
  final unseen = context.cardsUnseen;
  // Hand-built or inconsistent state: nothing sound to sample from.
  if (need.values.fold(0, (a, b) => a + b) != unseen.length) return null;

  for (var attempt = 0; attempt < 20; attempt++) {
    final respectVoids = attempt < 15;
    bool open(int seat, Suit suit) =>
        !(respectVoids && context.isKnownVoid(seat, suit));
    final left = Map.of(need);
    final hands = {for (final seat in seats) seat: <PlayingCard>[]};
    // Place the most constrained suits first so voids rarely dead-end.
    final deck = [...unseen]..shuffle(random);
    deck.sort(
      (a, b) => seats
          .where((seat) => open(seat, a.suit))
          .length
          .compareTo(seats.where((seat) => open(seat, b.suit)).length),
    );
    var ok = true;
    for (final card in deck) {
      final eligible = seats
          .where((seat) => left[seat]! > 0 && open(seat, card.suit))
          .toList();
      if (eligible.isEmpty) {
        ok = false;
        break;
      }
      var pick = random.nextInt(
        eligible.fold(0, (sum, seat) => sum + left[seat]!),
      );
      final seat = eligible.firstWhere((seat) {
        pick -= left[seat]!;
        return pick < 0;
      });
      hands[seat]!.add(card);
      left[seat] = left[seat]! - 1;
    }
    if (ok) return hands;
  }
  return null;
}

/// Plays [card] for the bot, then every remaining card with the medium
/// policy. Returns +1/-1 for a team win/loss plus 0.1 per ten of margin.
double _playOut(
  GameState game,
  _DecisionContext context,
  PlayingCard card,
  Map<int, List<PlayingCard>> hands,
  BotMemory memory,
  Random random,
) {
  var state = game;
  var seat = context.botSeat;
  var next = card;
  while (true) {
    final trick = state.currentTrick!;
    final plays = [...trick.plays, TrickPlay(seat, next)];
    final leadSuit = trick.plays.isEmpty ? next.suit : state.leadSuit!;
    final setsTrump =
        state.trumpSuit == null &&
        trick.plays.isNotEmpty &&
        next.suit != leadSuit;
    final trumpSuit = setsTrump ? next.suit : state.trumpSuit;
    state = state.copyWith(
      leadSuit: leadSuit,
      trumpSuit: trumpSuit,
      currentTrick: CurrentTrick(leaderSeat: trick.leaderSeat, plays: plays),
      currentTurnSeat: GameState.nextSeat(seat),
    );

    if (plays.length == 4) {
      final winner = trickWinner(plays, leadSuit, trumpSuit);
      final team = GameState.teamForSeat(winner.seat);
      final tens = Map<String, String?>.from(state.collectedTens.tens);
      for (final play in plays) {
        if (play.card.isTen) tens[play.card.id] = team;
        memory.recordPlay(play.seat, play.card, leadSuit);
      }
      final ids = plays.map((play) => play.card.id);
      TrickPile add(TrickPile pile) => TrickPile(
        trickCount: pile.trickCount + 1,
        cards: [...pile.cards, ...ids],
      );
      final pileA = team == 'teamA' ? add(state.trickPileA) : state.trickPileA;
      final pileB = team == 'teamB' ? add(state.trickPileB) : state.trickPileB;
      final outcome = evaluateWinner(
        collectedTens: tens,
        trickCounts: {'teamA': pileA.trickCount, 'teamB': pileB.trickCount},
      );
      if (outcome.team != null) {
        final collected = CollectedTens(tens: tens);
        final margin =
            collected.tensForTeam(context.botTeam) -
            collected.tensForTeam(
              context.botTeam == 'teamA' ? 'teamB' : 'teamA',
            );
        return (outcome.team == context.botTeam ? 1 : -1) + 0.1 * margin;
      }
      state = state.copyWith(
        collectedTens: CollectedTens(tens: tens),
        trickPileA: pileA,
        trickPileB: pileB,
        trickNumber: state.trickNumber + 1,
        currentTurnSeat: winner.seat,
        leadSuit: null,
        currentTrick: CurrentTrick(leaderSeat: winner.seat),
      );
    }

    seat = state.currentTurnSeat!;
    final hand = hands[seat]!;
    next = PlayingCard.fromId(
      chooseBotCard(
        hand: [for (final held in hand) held.id],
        gameState: state,
        botSeat: seat,
        memory: memory,
        random: random,
      ),
    );
    hand.remove(next);
  }
}

int _compareEvaluations(BotCardEvaluation a, BotCardEvaluation b) {
  final scoreComparison = b.totalScore.compareTo(a.totalScore);
  if (scoreComparison != 0) return scoreComparison;
  final rankComparison = a.card.rank.value.compareTo(b.card.rank.value);
  if (rankComparison != 0) return rankComparison;
  return a.card.suit.index.compareTo(b.card.suit.index);
}
