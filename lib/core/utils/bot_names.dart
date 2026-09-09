import 'dart:math';

const botNames = [
  'Sheru',
  'Ustad Ji',
  'Chaudhary Cardwala',
  '10 Ka Baadshah',
  'Chikna Joker',
  'Munna Trumpwala',
  'Chintu Cutlet',
  'Lala Lakhpati',
  'Professor Patta',
  'Bunty Badshah',
  'Golu Gambler',
  'Mirchi Master',
  'Sultan of Suits',
  'Kallu Calculator',
  'Pandit Pakad',
  'Nawab of Naipes',
  'Raja Rummy',
  'Dilli Ka Don',
  'Patta Prasad',
  'Trump Singh',
];

final _rng = Random();

String pickBotName(Set<String> usedNames) {
  final available = botNames.where((n) => !usedNames.contains(n)).toList();
  if (available.isEmpty) return 'Bot ${_rng.nextInt(999)}';
  return available[_rng.nextInt(available.length)];
}
