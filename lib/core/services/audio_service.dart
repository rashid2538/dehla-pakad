import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum GameSound {
  cardPlay('sounds/card_play.mp3'),
  cardDeal('sounds/card_deal.mp3'),
  turnStart('sounds/turn_start.mp3'),
  trumpDeclared('sounds/trump_declared.mp3'),
  trickWon('sounds/trick_won.mp3'),
  trickLost('sounds/trick_lost.mp3'),
  tenCollected('sounds/ten_collected.mp3'),
  allTens('sounds/all_tens.mp3'),
  victory('sounds/victory.mp3'),
  defeat('sounds/defeat.mp3'),
  playerJoin('sounds/player_join.mp3'),
  playerLeave('sounds/player_leave.mp3'),
  error('sounds/error.mp3'),
  gameStart('sounds/game_start.mp3');

  final String path;
  const GameSound(this.path);
}

class AudioService {
  static final AudioService instance = AudioService._();
  AudioService._();

  bool _muted = false;
  double _volume = 0.7;
  DateTime? _lastPlayTime;
  GameSound? _lastSound;

  bool get muted => _muted;
  double get volume => _volume;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _muted = prefs.getBool('audio_muted') ?? false;
    _volume = prefs.getDouble('audio_volume') ?? 0.7;
  }

  Future<void> play(GameSound sound, {double? volume}) async {
    if (_muted) return;

    final now = DateTime.now();
    if (_lastSound == sound &&
        _lastPlayTime != null &&
        now.difference(_lastPlayTime!).inMilliseconds < 50) {
      return;
    }
    _lastSound = sound;
    _lastPlayTime = now;

    try {
      final player = AudioPlayer();
      await player.setVolume((volume ?? _volume).clamp(0.0, 1.0));
      await player.play(AssetSource(sound.path));
      player.onPlayerComplete.first.then((_) => player.dispose());
    } catch (_) {}
  }

  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 1.0);
    (await SharedPreferences.getInstance()).setDouble('audio_volume', _volume);
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    (await SharedPreferences.getInstance()).setBool('audio_muted', _muted);
  }
}

class HapticService {
  static void light() => HapticFeedback.lightImpact();
  static void medium() => HapticFeedback.mediumImpact();
  static void heavy() => HapticFeedback.heavyImpact();
  static void selection() => HapticFeedback.selectionClick();
}
