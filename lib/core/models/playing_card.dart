enum Suit {
  spades('S', '♠'),
  hearts('H', '♥'),
  diamonds('D', '♦'),
  clubs('C', '♣');

  const Suit(this.letter, this.symbol);
  final String letter;
  final String symbol;

  static Suit fromLetter(String l) =>
      Suit.values.firstWhere((s) => s.letter == l);
}

enum Rank {
  two('2', 2),
  three('3', 3),
  four('4', 4),
  five('5', 5),
  six('6', 6),
  seven('7', 7),
  eight('8', 8),
  nine('9', 9),
  ten('10', 10),
  jack('J', 11),
  queen('Q', 12),
  king('K', 13),
  ace('A', 14);

  const Rank(this.symbol, this.value);
  final String symbol;
  final int value;

  static Rank fromSymbol(String s) =>
      Rank.values.firstWhere((r) => r.symbol == s);
}

class PlayingCard implements Comparable<PlayingCard> {
  final Suit suit;
  final Rank rank;

  const PlayingCard(this.suit, this.rank);

  String get id => '${rank.symbol}${suit.letter}';
  bool get isTen => rank == Rank.ten;

  factory PlayingCard.fromId(String id) {
    // "10H" is 3 chars, everything else is 2
    final suitLetter = id[id.length - 1];
    final rankSymbol = id.substring(0, id.length - 1);
    return PlayingCard(Suit.fromLetter(suitLetter), Rank.fromSymbol(rankSymbol));
  }

  static List<PlayingCard> get fullDeck => [
        for (final suit in Suit.values)
          for (final rank in Rank.values) PlayingCard(suit, rank),
      ];

  @override
  int compareTo(PlayingCard other) => rank.value.compareTo(other.rank.value);

  @override
  bool operator ==(Object other) =>
      other is PlayingCard && other.suit == suit && other.rank == rank;

  @override
  int get hashCode => Object.hash(suit, rank);

  @override
  String toString() => id;
}
